import BuzzKit
@testable import Hive
import Testing

@Suite("Channel access banner")
struct ChannelAccessBannerTests {
    @Test("a hidden DM says nothing, because hiding is a choice and not a loss of access")
    func hiddenDirectMessageShowsNoBanner() {
        #expect(ChannelAccessBanner.notice(for: .hidden) == nil)
        #expect(ChannelAccessBanner.notice(for: .active) == nil)
        #expect(ChannelAccessState.hidden.isWritable)
    }

    @Test("every state that really is a loss of access explains itself and says it is read-only")
    func lostAccessStatesExplainThemselves() throws {
        for state in [ChannelAccessState.archived, .notMember, .unavailable, .deleted] {
            let notice = try #require(
                ChannelAccessBanner.notice(for: state),
                "\(state.rawValue) must explain itself"
            )
            #expect(notice.message.hasSuffix("read-only."))
            #expect(!notice.symbol.isEmpty)
            #expect(!state.isWritable)
        }
    }
}
