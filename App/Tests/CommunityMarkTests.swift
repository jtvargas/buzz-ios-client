@testable import Hive
import Testing

/// The mark's text fallback: a pure rule for what a rendered hexagon cannot expose to a test.
@Suite struct CommunityMarkTests {
    @Test func initialsAreUppercaseAndNameBounded() {
        #expect(CommunityMark.initials(for: "Hive") == "H")
        #expect(CommunityMark.initials(for: "Bitcoiners Community") == "BC")
        #expect(CommunityMark.initials(for: "  hive  ") == "H")
        #expect(CommunityMark.initials(for: "123") == "?")
    }
}
