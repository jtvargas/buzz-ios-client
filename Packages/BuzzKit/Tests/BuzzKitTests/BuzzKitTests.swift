import Testing
@testable import BuzzKit

@Test func versionMatchesCore() {
    #expect(!BuzzKit.version.isEmpty)
}
