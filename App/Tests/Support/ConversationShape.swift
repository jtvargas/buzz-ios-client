import BuzzKit
@testable import Hive

/// A rendered conversation as a flat list of strings: `"day"` for a separator and the
/// message's content for a row.
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
        case let .message(row): row.content
        }
    }
}

/// One synthetic row, for the pure grouping and tail tests that are about ordering
/// rather than about what the store returns.
func makeRow(
    id: String,
    at createdAt: Int64,
    content: String? = nil,
    pubkey: String = "author"
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
        parentID: nil,
        rootID: nil,
        replyCount: 0,
        lastReplyAt: nil
    )
}
