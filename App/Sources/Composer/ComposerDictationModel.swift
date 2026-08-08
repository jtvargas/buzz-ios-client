import AVFAudio
import Foundation
import Observation
import Speech

struct ComposerDictationNotice: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
    let offersSettings: Bool
}

/// One composer's on-device dictation session. The baseline draft is immutable for the
/// session, so every volatile result is a fresh replacement and Cancel can restore exactly.
@MainActor
@Observable
final class ComposerDictationModel {
    enum Phase: Equatable {
        case idle
        case preparing
        case listening
        case finishing
    }

    private(set) var phase: Phase = .idle
    private(set) var document: MentionDraft?
    /// The amplitude history the waveform draws, oldest first.
    ///
    /// Sized to what a composer-width track actually shows at the drawing's own pitch rather
    /// than to a round number — see ``DictationWaveform``. Holding more would be history
    /// nobody sees; holding fewer would stretch the drawing and lose the density the owner
    /// asked for. A narrow screen simply draws the newest of these.
    private(set) var levels = Array(
        repeating: Float.zero,
        count: DictationWaveform.barCount(forWidth: 260)
    )
    private(set) var preparationProgress: Double?
    var notice: ComposerDictationNotice?

    var isActive: Bool { phase != .idle }
    var canFinish: Bool { phase == .listening }
    /// Whether the speech model is still being fetched. Drawn inside the microphone button
    /// rather than in the row, so the press is answered where it was made.
    var isPreparing: Bool {
        if case .preparing = phase { return true }
        return false
    }
    /// Whether the ✕ / waveform / ✓ row replaces the ordinary controls.
    ///
    /// Not simply ``isActive``: `preparing` deliberately keeps the ordinary row, because a
    /// waveform with nothing to draw yet is a surface arriving before it has anything to say.
    var showsDictationRow: Bool { isActive && !isPreparing }

    private var baseline = MentionDraft()
    private var insertionRange = NSRange(location: 0, length: 0)
    private var finalizedTranscript = ""
    private var volatileTranscript = ""
    private var reservedLocale: Locale?
    private var didRequestSpeechAuthorization = false
    private var isTerminating = false
    private var acceptsResults = false

    private var capture: ComposerAudioCapture?
    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var startTask: Task<Void, Never>?
    private var inputTask: Task<Void, Never>?
    private var resultTask: Task<Void, Never>?
    private var levelTask: Task<Void, Never>?
    private var interruptionTask: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?

    func start(from document: MentionDraft, selection: NSRange) {
        guard phase == .idle else { return }
        baseline = document
        self.document = document
        insertionRange = ComposerDictationSupport.clamped(selection, in: document.text)
        finalizedTranscript = ""
        volatileTranscript = ""
        levels = Array(repeating: 0, count: levels.count)
        preparationProgress = nil
        didRequestSpeechAuthorization = false
        isTerminating = false
        acceptsResults = true
        phase = .preparing
        startTask = Task { [weak self] in
            await self?.beginSession()
        }
    }

    func cancel() {
        guard phase != .idle else { return }
        acceptsResults = false
        document = baseline
        phase = .finishing
        startTask?.cancel()
        Task { [weak self] in
            guard let self else { return }
            await self.cancelSession()
            self.phase = .idle
        }
    }

    func finish() {
        guard phase == .listening else { return }
        phase = .finishing
        Task { [weak self] in
            await self?.finishSession(interrupted: false)
        }
    }

    func cancelForDisappearance() {
        guard phase != .idle else { return }
        acceptsResults = false
        document = baseline
        phase = .idle
        startTask?.cancel()
        Task { [weak self] in
            await self?.cancelSession()
        }
    }
}

private extension ComposerDictationModel {
    private func beginSession() async {
        do {
            guard await ComposerDictationSupport.requestMicrophonePermission() else {
                throw DictationError.microphoneDenied
            }
            try Task.checkCancellation()
            try await configureAndStart()
        } catch is CancellationError {
            await cancelSession()
        } catch {
            await handleAnalyzerOrStartupFailure(error)
        }
    }

    private func configureAndStart() async throws {
        let transcriber = try await makeReservedTranscriber()
        try await ensureAssets(for: transcriber)
        try Task.checkCancellation()
        let modules: [any SpeechModule] = [transcriber]
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: modules
        ) else {
            throw DictationError.audioFormat
        }
        let input = try await startAnalyzer(transcriber, modules: modules, format: analyzerFormat)
        let capture = ComposerAudioCapture()
        let streams = try await capture.start()
        self.capture = capture
        startStreamTasks(streams, input: input, analyzerFormat: analyzerFormat)
        phase = .listening
    }

    private func makeReservedTranscriber() async throws -> SpeechTranscriber {
        guard SpeechTranscriber.isAvailable else { throw DictationError.unavailable }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current) else {
            throw DictationError.unsupportedLocale
        }
        guard try await AssetInventory.reserve(locale: locale) else {
            throw DictationError.localeCapacity
        }
        reservedLocale = locale
        return SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [.etiquetteReplacements],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: []
        )
    }

    private func startAnalyzer(
        _ transcriber: SpeechTranscriber,
        modules: [any SpeechModule],
        format: AVAudioFormat
    ) async throws -> AsyncStream<AnalyzerInput>.Continuation {
        let analyzer = SpeechAnalyzer(modules: modules)
        try await analyzer.prepareToAnalyze(in: format)
        let input = AsyncStream.makeStream(of: AnalyzerInput.self, bufferingPolicy: .unbounded)
        inputContinuation = input.continuation
        self.analyzer = analyzer
        try await analyzer.start(inputSequence: input.stream)
        resultTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard !Task.isCancelled else { return }
                    self?.receive(result)
                }
            } catch {
                await self?.handleRuntimeFailure(error)
            }
        }
        return input.continuation
    }

    private func startStreamTasks(
        _ streams: ComposerAudioCapture.Streams,
        input continuation: AsyncStream<AnalyzerInput>.Continuation,
        analyzerFormat: AVAudioFormat
    ) {
        let converter = ComposerAnalyzerInputConverter(outputFormat: analyzerFormat)
        inputTask = Task.detached { [weak self] in
            do {
                for await buffer in streams.buffers {
                    guard !Task.isCancelled else { break }
                    let converted = try converter.convert(buffer)
                    continuation.yield(AnalyzerInput(buffer: converted))
                }
                continuation.finish()
            } catch {
                continuation.finish()
                await self?.handleRuntimeFailure(error)
            }
        }
        levelTask = Task { [weak self] in
            for await level in streams.levels {
                guard !Task.isCancelled else { return }
                self?.receiveLevel(level)
                // The stream keeps only its newest value while this sleeps, so SwiftUI
                // receives at most 30 paints per second without back-pressuring speech.
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
        interruptionTask = Task { [weak self] in
            for await _ in streams.interruptions {
                guard !Task.isCancelled else { return }
                await self?.finishSession(interrupted: true)
                return
            }
        }
    }

    private func ensureAssets(for transcriber: SpeechTranscriber) async throws {
        let modules: [any SpeechModule] = [transcriber]
        switch await AssetInventory.status(forModules: modules) {
        case .unsupported:
            throw DictationError.unsupportedLocale
        case .installed:
            return
        case .supported, .downloading:
            break
        @unknown default:
            throw DictationError.assetInstallation
        }

        if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
            preparationProgress = request.progress.fractionCompleted
            progressTask = Task { [weak self] in
                while !Task.isCancelled, !request.progress.isFinished {
                    self?.preparationProgress = request.progress.fractionCompleted
                    try? await Task.sleep(for: .milliseconds(100))
                }
                self?.preparationProgress = request.progress.fractionCompleted
            }
            defer {
                progressTask?.cancel()
                progressTask = nil
            }
            try await request.downloadAndInstall()
            return
        }

        while await AssetInventory.status(forModules: modules) == .downloading {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(250))
        }
        guard await AssetInventory.status(forModules: modules) == .installed else {
            throw DictationError.assetInstallation
        }
    }
}

private extension ComposerDictationModel {
    func receive(_ result: SpeechTranscriber.Result) {
        guard acceptsResults else { return }
        let text = String(result.text.characters)
        if result.isFinal {
            finalizedTranscript += text
            volatileTranscript = ""
        } else {
            volatileTranscript = text
        }
        updateDocument()
    }

    func updateDocument() {
        let transcript = (finalizedTranscript + volatileTranscript)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else {
            document = baseline
            return
        }
        let source = baseline.text as NSString
        var replacement = transcript
        if insertionRange.location > 0,
           !ComposerDictationSupport.isWhitespace(source.character(at: insertionRange.location - 1)) {
            replacement = " " + replacement
        }
        let rightEdge = NSMaxRange(insertionRange)
        if rightEdge < source.length,
           !ComposerDictationSupport.isWhitespace(source.character(at: rightEdge)) {
            replacement += " "
        }
        var updated = baseline
        updated.replaceCharacters(in: insertionRange, with: replacement)
        document = updated
    }

    func receiveLevel(_ sample: Float) {
        guard phase == .listening else { return }
        let previous = levels.last ?? 0
        let smoothed = previous * 0.62 + sample * 0.38
        levels.removeFirst()
        levels.append(smoothed)
    }

    func finishSession(interrupted: Bool) async {
        guard !isTerminating, phase == .listening || phase == .finishing else { return }
        isTerminating = true
        phase = .finishing
        await capture?.stop()
        await inputTask?.value
        do {
            try await analyzer?.finalizeAndFinishThroughEndOfInput()
            await resultTask?.value
        } catch {
            if !interrupted {
                notice = ComposerDictationSupport.notice(for: error)
            }
        }
        await releaseSessionResources(cancelResults: false)
        acceptsResults = false
        isTerminating = false
        phase = .idle
        if interrupted {
            notice = ComposerDictationNotice(
                title: "Dictation Stopped",
                message: "An audio interruption stopped dictation. The text heard so far was kept.",
                offersSettings: false
            )
        }
    }

    func cancelSession() async {
        isTerminating = true
        acceptsResults = false
        await capture?.stop()
        inputContinuation?.finish()
        await analyzer?.cancelAndFinishNow()
        await releaseSessionResources(cancelResults: true)
        isTerminating = false
    }

    func handleRuntimeFailure(_ error: Error) async {
        guard !isTerminating, phase != .idle else { return }
        await handleAnalyzerOrStartupFailure(error)
    }

    func handleAnalyzerOrStartupFailure(_ error: Error) async {
        if ComposerDictationSupport.isSpeechAuthorizationFailure(error),
           !didRequestSpeechAuthorization {
            didRequestSpeechAuthorization = true
            await cancelSession()
            guard await ComposerDictationSupport.requestSpeechAuthorization() else {
                fail(with: DictationError.speechDenied)
                return
            }
            isTerminating = false
            acceptsResults = true
            phase = .preparing
            startTask = Task { [weak self] in
                await self?.beginSession()
            }
            return
        }
        await cancelSession()
        fail(with: error)
    }

    func fail(with error: Error) {
        acceptsResults = false
        document = baseline
        phase = .idle
        notice = ComposerDictationSupport.notice(for: error)
    }

    func releaseSessionResources(cancelResults: Bool) async {
        if cancelResults { resultTask?.cancel() }
        inputTask?.cancel()
        levelTask?.cancel()
        interruptionTask?.cancel()
        progressTask?.cancel()
        inputContinuation?.finish()
        if let reservedLocale {
            await AssetInventory.release(reservedLocale: reservedLocale)
        }
        capture = nil
        analyzer = nil
        inputContinuation = nil
        inputTask = nil
        resultTask = nil
        levelTask = nil
        interruptionTask = nil
        progressTask = nil
        reservedLocale = nil
        preparationProgress = nil
    }
}
