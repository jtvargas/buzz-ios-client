import Accelerate
@preconcurrency import AVFAudio
import Foundation

/// Owns the realtime microphone objects. The tap never crosses into observable state:
/// speech buffers are lossless, while paint samples deliberately keep only the newest level.
actor ComposerAudioCapture {
    private struct EngineInput {
        let engine: AVAudioEngine
        let node: AVAudioInputNode
        let format: AVAudioFormat
    }

    /// The AVAudio buffer crosses exactly once from the tap into the single conversion task.
    /// AVFAudio has not annotated it Sendable, while Speech's own `AnalyzerInput` wraps that
    /// same buffer as `@unchecked Sendable`; this bundle makes the identical ownership claim.
    struct Streams: @unchecked Sendable {
        let buffers: AsyncStream<AVAudioPCMBuffer>
        let levels: AsyncStream<Float>
        let interruptions: AsyncStream<Void>
        let format: AVAudioFormat
    }

    enum CaptureError: LocalizedError {
        case noInput

        var errorDescription: String? {
            "No microphone input is available."
        }
    }

    private var engine: AVAudioEngine?
    private var bufferContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var levelContinuation: AsyncStream<Float>.Continuation?
    private var interruptionContinuation: AsyncStream<Void>.Continuation?
    private var interruptionObserver: NSObjectProtocol?

    func start() throws -> Streams {
        let session = try activateAudioSession()

        let engineInput = try makeEngine(session: session)
        let engine = engineInput.engine
        let input = engineInput.node
        let format = engineInput.format

        let buffers = AsyncStream.makeStream(
            of: AVAudioPCMBuffer.self,
            bufferingPolicy: .unbounded
        )
        let levels = AsyncStream.makeStream(
            of: Float.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        let interruptions = AsyncStream.makeStream(
            of: Void.self,
            bufferingPolicy: .bufferingNewest(1)
        )

        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
            buffers.continuation.yield(buffer)
            levels.continuation.yield(Self.normalizedLevel(in: buffer))
        }

        let observer = makeInterruptionObserver(
            session: session,
            continuation: interruptions.continuation
        )

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            NotificationCenter.default.removeObserver(observer)
            buffers.continuation.finish()
            levels.continuation.finish()
            interruptions.continuation.finish()
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw error
        }

        self.engine = engine
        bufferContinuation = buffers.continuation
        levelContinuation = levels.continuation
        interruptionContinuation = interruptions.continuation
        interruptionObserver = observer
        return Streams(
            buffers: buffers.stream,
            levels: levels.stream,
            interruptions: interruptions.stream,
            format: format
        )
    }

    private func activateAudioSession() throws -> AVAudioSession {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .spokenAudio)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        return session
    }

    private func makeEngine(
        session: AVAudioSession
    ) throws -> EngineInput {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw CaptureError.noInput
        }
        return EngineInput(engine: engine, node: input, format: format)
    }

    private func makeInterruptionObserver(
        session: AVAudioSession,
        continuation: AsyncStream<Void>.Continuation
    ) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: nil
        ) { _ in
            // The first notification is interruption-began. Capture is torn down before
            // interruption-ended can arrive, so one signal describes the whole event.
            continuation.yield(())
        }
    }

    func stop() {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            engine.reset()
        }
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
        bufferContinuation?.finish()
        levelContinuation?.finish()
        interruptionContinuation?.finish()
        bufferContinuation = nil
        levelContinuation = nil
        interruptionContinuation = nil
        interruptionObserver = nil
        engine = nil
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }

    nonisolated private static func normalizedLevel(in buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?.pointee, buffer.frameLength > 0 else {
            return 0
        }
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(buffer.frameLength))
        let decibels = 20 * log10(max(rms, 0.000_001))
        return min(max((decibels + 60) / 60, 0), 1)
    }
}

/// `AVAudioConverter` is stateful. One instance lives on the single input task, so no lock
/// is needed and conversion never runs on the main actor or the realtime audio callback.
final class ComposerAnalyzerInputConverter: @unchecked Sendable {
    private final class InputSupply: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
        var didSupply = false

        init(buffer: AVAudioPCMBuffer) {
            self.buffer = buffer
        }
    }

    enum ConversionError: LocalizedError {
        case unavailable
        case failed(Error?)

        var errorDescription: String? {
            switch self {
            case .unavailable: "The microphone format cannot be prepared for dictation."
            case let .failed(error): error?.localizedDescription ?? "Audio conversion failed."
            }
        }
    }

    private let outputFormat: AVAudioFormat
    private var converter: AVAudioConverter?

    init(outputFormat: AVAudioFormat) {
        self.outputFormat = outputFormat
    }

    func convert(_ input: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        if input.format == outputFormat { return input }
        if converter == nil {
            converter = AVAudioConverter(from: input.format, to: outputFormat)
        }
        guard let converter else { throw ConversionError.unavailable }

        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * ratio)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw ConversionError.unavailable
        }

        let supply = InputSupply(buffer: input)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, status in
            guard !supply.didSupply else {
                status.pointee = .noDataNow
                return nil
            }
            supply.didSupply = true
            status.pointee = .haveData
            return supply.buffer
        }
        guard status != .error else { throw ConversionError.failed(conversionError) }
        return output
    }
}
