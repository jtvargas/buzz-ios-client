import Foundation
import GRDB

/// The three prose fields the relay keeps about a channel, read together because
/// they are only ever drawn together.
///
/// Kept off ``ChannelListRow`` on purpose. The sidebar draws none of them, and a
/// channel list that carried three strings per row so that one sheet could read them
/// would pay for them on every keystroke of a filter.
public struct ChannelContext: Sendable, Equatable {
    /// What the channel *is*. The relay's `about` tag on kind:39000, and what the
    /// create sheet calls Description.
    public let description: String?
    /// What it is about *now* — Slack's topic, changed often.
    public let topic: String?
    /// Why it exists. Set by the relay's channel templates and by the CLI; rarely
    /// edited by hand, which is why it reads as the most stable of the three.
    public let purpose: String?

    public init(description: String?, topic: String?, purpose: String?) {
        self.description = description
        self.topic = topic
        self.purpose = purpose
    }

    /// Whether the channel has told a reader anything at all. A sheet with three
    /// "Not set" cards is worse than a sheet with no section.
    public var isEmpty: Bool {
        [description, topic, purpose].allSatisfy { ($0 ?? "").trimmed.isEmpty }
    }
}

public extension BuzzEventStore {
    /// One channel's description, topic and purpose, or an empty context when the
    /// channel's metadata has never arrived.
    nonisolated func channelContext(_ channel: String) throws -> ChannelContext {
        try reader.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT about, topic, purpose FROM channel WHERE id = ?",
                arguments: [channel]
            ) else {
                return ChannelContext(description: nil, topic: nil, purpose: nil)
            }
            return ChannelContext(
                description: row["about"],
                topic: row["topic"],
                purpose: row["purpose"]
            )
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
