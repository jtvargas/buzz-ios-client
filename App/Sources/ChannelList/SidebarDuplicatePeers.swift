import BuzzKit
import Foundation

extension SidebarContent {
    /// One row per person, however many conversations the relay holds with them.
    ///
    /// A one-to-one conversation is *with somebody*, and the sidebar row is that person —
    /// their name, their face. So two rows for one person are not two things a reader can
    /// choose between: they are the same name, the same avatar, and the same presence dot
    /// twice, and which one holds the message they are looking for is not knowable from
    /// the list. That is the defect this collapses.
    ///
    /// It is not hypothetical. Rotating an agent's key (NIP-IA archive with `replaced-by`)
    /// *moves* the old DM to the replacement — the relay adds the new key and removes the
    /// old one — rather than merging it into the pair's existing conversation, so both
    /// channels end up with an identical roster. Measured on the homelab relay
    /// 2026-08-06: 25 two-member DM channels for 18 distinct pairs, three of them the
    /// same two people. The relay's unique `participant_hash` index does not catch it
    /// because the hash is never recomputed after the roster is rewritten.
    ///
    /// Only one-to-one conversations, which are the ones with a ``ConversationIdentity/peer``
    /// — a group is titled by everyone in it, so two groups with the same roster would at
    /// least be *readable* as duplicates, and none were measured. A channel is never
    /// collapsed: two channels with the same name are two rooms.
    ///
    /// The survivor is what the reader would have reached for anyway, and the rule is total
    /// so the choice cannot flicker between passes — see ``outranks(_:_:)``. The rows that
    /// lose are dropped from the sidebar only: they keep their messages, and search and the
    /// new-message sheet still reach them. Merging them is the relay's to do.
    static func collapsingDuplicatePeers(_ rows: [SidebarRow]) -> [SidebarRow] {
        var winners: [String: Int] = [:]
        var collapsed: Set<Int> = []
        for (index, row) in rows.enumerated() {
            guard let peer = row.conversation.peer else { continue }
            guard let incumbent = winners[peer] else {
                winners[peer] = index
                continue
            }
            if outranks(row, rows[incumbent]) {
                winners[peer] = index
                collapsed.insert(incumbent)
            } else {
                collapsed.insert(index)
            }
        }
        guard !collapsed.isEmpty else { return rows }
        return rows.enumerated().filter { !collapsed.contains($0.offset) }.map(\.element)
    }

    /// Which of two conversations with the same person the sidebar keeps.
    ///
    /// A star first, because it is the one thing here the reader *said* about a specific
    /// conversation — collapsing the starred one away would empty a heading they filled by
    /// hand. Then ``precedes(_:_:)``, the sidebar's own order, which puts the newest
    /// activity first: the conversation somebody is actually in is the one a tap should
    /// reach. Its final tie-break on the channel id is what makes this total, so two silent
    /// duplicates resolve the same way on every pass rather than swapping under the reader.
    ///
    /// (The title comparison inside `precedes` cannot decide anything here — same person,
    /// same resolved name — which is exactly why the id tie-break has to be there.)
    static func outranks(_ lhs: SidebarRow, _ rhs: SidebarRow) -> Bool {
        if lhs.isStarred != rhs.isStarred { return lhs.isStarred }
        return precedes(lhs, rhs)
    }
}
