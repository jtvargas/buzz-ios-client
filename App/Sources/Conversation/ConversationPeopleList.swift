import BuzzKit
import SwiftUI

/// One person in a conversation's people list.
///
/// A view-level shape rather than ``MemberProfile`` because the two lists this draws are
/// not both rosters: a channel's people come from the relay-signed roster and carry a
/// role, and a thread's people are simply whoever has spoken in it and carry a count of
/// what they said. Naming the *line under the name* rather than the source is what lets
/// one row type draw both without either list having to pretend to be the other.
struct ConversationPerson: Identifiable, Hashable {
    let pubkey: String
    /// The second line, or `nil` for no second line at all. Not an empty string: a row
    /// that reserves space for a line it has nothing to put in reads as a rendering bug.
    let detail: String?
    /// The artwork this person's own record carried, used only when the shared directory
    /// has none. The directory is the first word — see ``ConversationPersonRow`` — but the
    /// roster's own row may have landed first, and a face is better than a monogram.
    let fallbackPicture: URL?

    var id: String { pubkey }

    init(pubkey: String, detail: String? = nil, fallbackPicture: URL? = nil) {
        self.pubkey = pubkey
        self.detail = detail
        self.fallbackPicture = fallbackPicture
    }

    /// A channel member, whose second line is the role the roster assigned them.
    init(member: MemberProfile) {
        let role = member.role?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.init(
            pubkey: member.pubkey,
            detail: role.isEmpty ? nil : role.capitalized,
            fallbackPicture: member.picture.flatMap(URL.init(string:))
        )
    }
}

extension ConversationPerson {
    /// Who has spoken in a thread, in the order they first did.
    ///
    /// First-appearance order rather than alphabetical, deliberately: a thread is a
    /// sequence, and the person who opened it is the one a reader is looking for first.
    /// Sorting by name would put them wherever the alphabet happens to.
    ///
    /// Every rendered row counts, including a deleted one — the reader sees "message
    /// deleted" sitting in the thread, so the person who left it is in the thread. Nothing
    /// here consults the channel roster: somebody can reply and then leave the channel,
    /// and their words stay.
    static func threadParticipants(in rows: [TimelineRow], root: String) -> [ConversationPerson] {
        let openerPubkey = rows.first { $0.id == root }?.pubkey
        var order: [String] = []
        var counts: [String: Int] = [:]
        for row in rows {
            if counts[row.pubkey] == nil { order.append(row.pubkey) }
            counts[row.pubkey, default: 0] += 1
        }
        return order.map { pubkey in
            // The opener's own opening message is not a reply, so it does not count as one.
            let replies = (counts[pubkey] ?? 0) - (pubkey == openerPubkey ? 1 : 0)
            return ConversationPerson(
                pubkey: pubkey,
                detail: threadDetail(isOpener: pubkey == openerPubkey, replies: replies)
            )
        }
    }

    private static func threadDetail(isOpener: Bool, replies: Int) -> String {
        let replyLabel = replies == 1 ? "1 reply" : "\(replies) replies"
        guard isOpener else { return replyLabel }
        // An opener who also replied gets both facts: which of the two matters depends on
        // what the reader is scanning for, and neither is long.
        return replies == 0 ? "Opened the thread" : "Opened the thread · \(replyLabel)"
    }
}

/// The people in a conversation: a face, a name, what they are here, and whether they
/// are here now.
///
/// Deliberately without its own navigation container or presentation detents — it is the
/// *contents*, drawn both as the body of ``ConversationPeopleSheet`` and as a push off the
/// channel details sheet. One list with two doors, for the reason the manage sheet has
/// two: a second list of the same people, assembled separately, is how two screens start
/// disagreeing about who is in a room.
struct ConversationPeopleList: View {
    let people: [ConversationPerson]
    /// Whether the roster is still arriving. Distinguished from "empty" so a list that has
    /// not read yet shows a spinner rather than claiming the room is deserted.
    let isLoading: Bool
    /// What to say when there is genuinely nobody to show.
    let emptyMessage: String
    /// The presence roster, owned by whoever presents this list — a `PresenceStore` stream
    /// is per-model, and a second one started here would be a second subscription for the
    /// same answer the presenting surface already has.
    let presence: PresenceModel
    /// What tapping somebody does, or `nil` for a list that only reads.
    ///
    /// Optional rather than always-on because two of this list's three call sites offer
    /// nothing to open: the channel roster and a thread's participants are read-only
    /// today, and a row that highlights under the finger and then does nothing reads as a
    /// broken control. The reactor sheet passes one.
    var onSelect: ((String) -> Void)?

    @Environment(\.entityNames) private var names

    var body: some View {
        List {
            Section {
                if people.isEmpty {
                    if isLoading {
                        ProgressView()
                    } else {
                        Text(emptyMessage)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(people) { person in
                        row(for: person)
                    }
                }
            } header: {
                if !people.isEmpty {
                    Text(Self.countLabel(people.count))
                }
            }
        }
    }

    /// One person, as a control where there is somewhere to go and as plain content
    /// where there is not.
    ///
    /// The branch is on a value fixed for the life of a call site, so the two forms never
    /// swap under a finger — a row that changed identity mid-press would lose the press.
    @ViewBuilder
    private func row(for person: ConversationPerson) -> some View {
        if let onSelect {
            Button { onSelect(person.pubkey) } label: {
                content(for: person)
            }
            // A full-width row in a list, so the row emphasis rather than the control's —
            // see ``PressFeedbackButtonStyle/Emphasis``.
            .buttonStyle(.hivePress(.row))
            .accessibilityHint("Double tap to view profile")
        } else {
            content(for: person)
        }
    }

    private func content(for person: ConversationPerson) -> some View {
        ConversationPersonRow(
            pubkey: person.pubkey,
            name: names.name(for: person.pubkey),
            picture: names.picture(for: person.pubkey) ?? person.fallbackPicture,
            initials: names.initials(for: person.pubkey),
            detail: person.detail,
            isOnline: presence.isOnline(person.pubkey)
        )
    }

    /// `1 person` / `12 people`. Written out rather than a bare number because it is a
    /// section header, where a lone `12` says nothing about what is being counted.
    static func countLabel(_ count: Int) -> String {
        count == 1 ? "1 person" : "\(count) people"
    }
}

/// One person's row, named and pictured through the shared directory rather than from
/// whatever the caller's own record carried, so somebody reads the same here as in the
/// timeline and in the channel details sheet.
struct ConversationPersonRow: View {
    let pubkey: String
    let name: String
    let picture: URL?
    let initials: String
    let detail: String?
    let isOnline: Bool

    var body: some View {
        HStack(spacing: 10) {
            AvatarView(url: picture, seed: pubkey, monogram: initials, size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.hive(.body, weight: .medium))
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.hive(.caption))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            PresenceDot(isOnline: isOnline)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(isOnline ? "Online" : "Offline")
    }
}
