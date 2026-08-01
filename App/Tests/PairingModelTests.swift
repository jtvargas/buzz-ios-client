import Foundation
@testable import Hive
import NostrCore
import Testing

/// View-model tests for the pairing flow: QR parsing, phase→screen mapping, and
/// user-action forwarding, all against a scripted ``PairingDriving`` — no crypto,
/// no socket.
@MainActor
@Suite struct PairingModelTests {
    static let validURI = "nostrpair://199e64ca60662cb2d6e91d16cb065be51ad74a6ee5f8c5b0fdc53d246611ed9a" +
        "?secret=a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2&relay=wss://pair.example"

    private func parkBriefly() async { try? await Task.sleep(for: .milliseconds(30)) }

    private func makeModel(
        _ session: FakePairingSession,
        onImported: @escaping () async -> Void = {}
    ) -> PairingModel {
        PairingModel(makeSession: { _ in session }, onImported: onImported)
    }

    @Test func badQRSetsScanErrorAndStaysScanning() {
        let model = makeModel(FakePairingSession())
        model.submitScan("not-a-pairing-uri")
        #expect(model.screen == .scanning)
        #expect(model.scanError != nil)
    }

    @Test func unsupportedVersionShowsUpdateMessage() {
        let model = makeModel(FakePairingSession())
        let uri = "nostrpair://199e64ca60662cb2d6e91d16cb065be51ad74a6ee5f8c5b0fdc53d246611ed9a" +
            "?secret=a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2&relay=wss://r.example&v=99"
        model.submitScan(uri)
        #expect(model.screen == .scanning)
        #expect(model.scanError?.contains("newer version") == true)
    }

    @Test func validQRStartsTheSession() async {
        let session = FakePairingSession()
        let model = makeModel(session)
        model.submitScan(Self.validURI)
        #expect(model.screen == .connecting)
        await parkBriefly()
        #expect(await session.started)
    }

    @Test func phasesMapToScreens() async {
        let session = FakePairingSession()
        let model = makeModel(session)
        model.submitScan(Self.validURI)
        await parkBriefly()

        await session.emit(.comparing(sasCode: "863346"))
        await parkBriefly()
        #expect(model.screen == .comparing(sasCode: "863346"))

        await session.emit(.transferring)
        await parkBriefly()
        #expect(model.screen == .transferring)
    }

    @Test func confirmAndCancelForwardToSession() async {
        let session = FakePairingSession()
        let model = makeModel(session)
        model.submitScan(Self.validURI)
        await parkBriefly()

        model.confirmSAS()
        await parkBriefly()
        #expect(await session.confirmed)

        model.cancel()
        await parkBriefly()
        #expect(await session.cancelled)
    }

    @Test func completionTriggersImport() async {
        let session = FakePairingSession()
        let imported = ImportFlag()
        let model = makeModel(session, onImported: { await imported.mark() })
        model.submitScan(Self.validURI)
        await parkBriefly()

        await session.emit(.completed)
        await parkBriefly()
        #expect(model.screen == .completed)
        #expect(await imported.wasCalled)
    }

    @Test func failureMapsToAFriendlyMessage() async {
        let session = FakePairingSession()
        let model = makeModel(session)
        model.submitScan(Self.validURI)
        await parkBriefly()

        await session.emit(.failed(.transcriptMismatch))
        await parkBriefly()
        guard case let .failed(message) = model.screen else {
            #expect(Bool(false), "expected a failed screen")
            return
        }
        #expect(message.contains("didn't match"))
    }

    /// A silent desktop is the most common way pairing fails, and the reason is
    /// never on screen: its code expires two minutes after it appears and then
    /// discards offers without a word. The message has to carry that window,
    /// because it is the only thing the reader can act on.
    @Test func aSilentDesktopIsExplainedByItsExpiringCode() async {
        let session = FakePairingSession()
        let model = makeModel(session)
        model.submitScan(Self.validURI)
        await parkBriefly()

        await session.emit(.failed(.timedOut))
        await parkBriefly()
        guard case let .failed(message) = model.screen else {
            #expect(Bool(false), "expected a failed screen")
            return
        }
        #expect(message.contains("two minutes"))
        #expect(message.contains("start pairing again"))
    }

    @Test func scanAgainResetsToScanning() async {
        let session = FakePairingSession()
        let model = makeModel(session)
        model.submitScan(Self.validURI)
        await parkBriefly()
        await session.emit(.failed(.timedOut))
        await parkBriefly()

        model.scanAgain()
        #expect(model.screen == .scanning)
        #expect(model.scanError == nil)
    }
}

/// A tiny async flag for asserting the import callback fired.
actor ImportFlag {
    private(set) var wasCalled = false
    func mark() { wasCalled = true }
}
