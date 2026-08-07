import Foundation
@testable import Hive
import Testing

@MainActor
@Suite("Composer preparation races")
struct ComposerPreparationRaceTests {
    static func waitUntil(
        _ condition: @MainActor () async -> Bool,
        within seconds: Double = 5
    ) async {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// The preparation task outlives a tile removed while its source is loading.
    /// Neither the preview nor the ready-state write may recreate that row.
    @Test("a tile removed during preparation does not come back when preparation lands")
    func removalDuringPreparationSticks() async throws {
        let gate = StubPickedItemGate()
        let model = ComposerAttachmentsModel()
        model.add([StubPickedItem(data: TestPicture.png(), gate: gate)])
        let id = try #require(model.attachments.first?.id)
        await Self.waitUntil { await gate.isWaiting }

        model.remove(id)
        #expect(model.attachments.isEmpty)
        await gate.release()

        // Give the resumed decode and both guarded writes every chance to finish.
        for _ in 0 ..< 100 { await Task.yield() }
        #expect(model.attachments.isEmpty)
        #expect(!model.hasSendableContent)
    }
}
