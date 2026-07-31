import BuzzKit
@testable import Hive

/// A rendered conversation as a flat list of strings: `"day"` for a separator,
/// `"notice"` for a relay notice, and the message's content for a row.
///
/// Day separators are *items* in the rendered list rather than headers on a row, so
/// what a grouping test needs to assert is the shape of that list — where the
/// separators fall, and that there is exactly one per local day. One line of
/// `["day", "monday", "day", "wednesday"]` says that far more legibly than indexing
/// into the enum case by case.
func shape(_ items: [ConversationItem]) -> [String] {
    items.map { item in
        switch item {
        case .day: "day"
        case let .message(row, _): row.content
        case .notice: "notice"
        }
    }
}

/// The same list, with every message that continues the block above it marked by a
/// leading `+` — a row that draws no avatar, no name and no time, and sits tight under
/// the one that named its author.
///
/// `["day", "one", "+two", "day", "three"]` is the whole assertion a grouping test wants
/// to make: which rows open a block, which stack under one, and where the furniture that
/// ends a block falls.
func groupedShape(_ items: [ConversationItem]) -> [String] {
    items.map { item in
        switch item {
        case .day: "day"
        case let .message(row, continuesGroup): (continuesGroup ? "+" : "") + row.content
        case .notice: "notice"
        }
    }
}

/// One synthetic row, for the pure grouping and tail tests that are about ordering
/// rather than about what the store returns.
func makeRow(
    id: String,
    at createdAt: Int64,
    content: String? = nil,
    pubkey: String = "author",
    parentID: String? = nil,
    media: [MessageMedia] = []
) -> TimelineRow {
    TimelineRow(
        id: id,
        pubkey: pubkey,
        createdAt: createdAt,
        content: content ?? id,
        isEdited: false,
        isDeleted: false,
        richContent: nil,
        delivery: .sent,
        authorName: nil,
        authorPicture: nil,
        parentID: parentID,
        rootID: parentID,
        replyCount: 0,
        lastReplyAt: nil,
        media: media
    )
}

/// One synthetic relay notice, as the store would hand it over.
///
/// `content` is the raw JSON body on purpose, and `notice` is what a decode of it
/// produced — the two together are the only way to build the case that matters most:
/// a row the store knows is a notice but could not decode, which must be dropped
/// rather than rendered as somebody's words.
func makeNoticeRow(
    id: String,
    at createdAt: Int64,
    body: String,
    notice: SystemNotice?
) -> TimelineRow {
    TimelineRow(
        id: id,
        pubkey: "relay",
        createdAt: createdAt,
        content: body,
        isEdited: false,
        isDeleted: false,
        richContent: nil,
        delivery: .sent,
        authorName: nil,
        authorPicture: nil,
        parentID: nil,
        rootID: nil,
        replyCount: 0,
        lastReplyAt: nil,
        notice: notice,
        isNotice: true
    )
}
