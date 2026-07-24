import Testing
@testable import NostrCore

@Test func versionIsSet() {
    #expect(!NostrCore.version.isEmpty)
}
