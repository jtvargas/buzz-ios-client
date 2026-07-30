import BuzzKit
import SwiftUI

struct ChannelAccessBanner: View {
    let state: ChannelAccessState

    /// What a state has to say for itself above the conversation, or `nil` where it has
    /// nothing to explain.
    ///
    /// Every banner here reports a *loss of access*, which is why each one ends by
    /// saying the history is read-only. A hidden DM is not one: it is off your sidebar
    /// because you put it there, it is still writable, and telling you so on the way in
    /// would be noise about a choice you already made.
    ///
    /// Static so the copy can be read by a test — nothing in the suite renders a view.
    static func notice(for state: ChannelAccessState) -> (message: String, symbol: String)? {
        switch state {
        case .active, .hidden:
            nil
        case .archived:
            ("This channel is archived. Its cached history is read-only.", "archivebox")
        case .notMember:
            ("You are no longer a member. Its cached history is read-only.", "person.slash")
        case .unavailable:
            ("This channel is unavailable. Its cached history is read-only.", "exclamationmark.triangle")
        case .deleted:
            ("This channel was deleted. Its cached history is read-only.", "trash")
        }
    }

    var body: some View {
        if let notice = Self.notice(for: state) {
            Label(notice.message, systemImage: notice.symbol)
                .font(.hive(.caption, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.thinMaterial, in: .rect(cornerRadius: 12))
                .accessibilityLabel(notice.message)
        }
    }
}
