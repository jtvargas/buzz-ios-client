import BuzzKit
import SwiftUI

struct ChannelAccessBanner: View {
    let state: ChannelAccessState

    var body: some View {
        if state != .active {
            Label(message, systemImage: symbol)
                .font(.hive(.caption, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.thinMaterial, in: .rect(cornerRadius: 12))
                .accessibilityLabel(message)
        }
    }

    private var message: String {
        switch state {
        case .active: ""
        case .archived: "This channel is archived. Its cached history is read-only."
        case .notMember: "You are no longer a member. Its cached history is read-only."
        case .unavailable: "This channel is unavailable. Its cached history is read-only."
        case .deleted: "This channel was deleted. Its cached history is read-only."
        }
    }

    private var symbol: String {
        switch state {
        case .active: "checkmark"
        case .archived: "archivebox"
        case .notMember: "person.slash"
        case .unavailable: "exclamationmark.triangle"
        case .deleted: "trash"
        }
    }
}
