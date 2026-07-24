import Foundation
@testable import NostrCore
import Testing

@Suite("TransportError taxonomy")
struct TransportErrorTests {
    @Test("Each case is distinct and equatable by payload")
    func equality() {
        #expect(TransportError.connectTimeout == .connectTimeout)
        #expect(TransportError.connectionClosed == .connectionClosed)
        #expect(TransportError.unsupportedFrame == .unsupportedFrame)
        #expect(TransportError.connectFailed("refused") == .connectFailed("refused"))
        #expect(TransportError.sendFailed("broken pipe") == .sendFailed("broken pipe"))
        #expect(TransportError.receiveFailed("reset") == .receiveFailed("reset"))
    }

    @Test("Cases with different payloads are not equal")
    func payloadSensitivity() {
        #expect(TransportError.connectFailed("a") != .connectFailed("b"))
        #expect(TransportError.sendFailed("a") != .receiveFailed("a"))
        #expect(TransportError.connectTimeout != .connectionClosed)
    }

    @Test(
        "Every case carries a non-empty, distinct description",
        arguments: [
            TransportError.connectTimeout,
            .connectFailed("refused"),
            .connectionClosed,
            .sendFailed("broken pipe"),
            .receiveFailed("reset"),
            .unsupportedFrame,
        ]
    )
    func descriptions(error: TransportError) {
        let description = try? #require(error.errorDescription)
        #expect(description?.isEmpty == false)
    }

    @Test("Descriptions are unique across the taxonomy")
    func descriptionsAreUnique() {
        let all: [TransportError] = [
            .connectTimeout,
            .connectFailed("x"),
            .connectionClosed,
            .sendFailed("x"),
            .receiveFailed("x"),
            .unsupportedFrame,
        ]
        let descriptions = Set(all.compactMap(\.errorDescription))
        #expect(descriptions.count == all.count)
    }
}
