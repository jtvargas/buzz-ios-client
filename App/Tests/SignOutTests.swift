@testable import Hive
import NostrCore
import Testing

/// Sign-out is a security boundary: it reports success only once the key is
/// confirmed removed, so a Keychain delete that throws — or silently leaves the
/// item — never masquerades as a completed sign-out.
/// A custody double whose delete may clear the key, throw and keep it, or silently
/// leave it in place.
private final class StubCustody: IdentityKeyCustody, @unchecked Sendable {
    enum Behavior { case clears, throwsAndKeeps, keepsSilently }
    enum Failure: Error { case delete }

    private var key: PrivateKey?
    private let behavior: Behavior

    init(key: PrivateKey?, behavior: Behavior) {
        self.key = key
        self.behavior = behavior
    }

    func delete() throws {
        switch behavior {
        case .clears: key = nil
        case .throwsAndKeeps: throw Failure.delete
        case .keepsSilently: break
        }
    }

    func loadPrivateKey() throws -> PrivateKey? { key }
}

@Suite struct SignOutTests {
    @Test func reportsSignedOutWhenKeyIsRemoved() throws {
        let custody = StubCustody(key: try PrivateKey(), behavior: .clears)
        #expect(deleteAndVerifyKey(custody) == .signedOut)
        #expect(try custody.loadPrivateKey() == nil)
    }

    @Test func reportsKeyNotClearedWhenDeleteThrows() throws {
        let custody = StubCustody(key: try PrivateKey(), behavior: .throwsAndKeeps)
        // The old code did `try? delete()` then unconditionally returned to onboarding;
        // this must instead refuse to report signed-out while the key is recoverable.
        #expect(deleteAndVerifyKey(custody) == .keyNotCleared)
        #expect(try custody.loadPrivateKey() != nil)
    }

    @Test func reportsKeyNotClearedWhenKeyPersistsSilently() throws {
        let custody = StubCustody(key: try PrivateKey(), behavior: .keepsSilently)
        #expect(deleteAndVerifyKey(custody) == .keyNotCleared)
    }
}
