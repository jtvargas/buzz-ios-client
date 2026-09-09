import SwiftUI

/// The lazy sidebar's unit of rendering. Unread state comes from the full channel snapshot;
/// appearing onscreen only creates the view and never starts a query or changes read state.
struct SidebarConversationButton: View {
    let row: SidebarRow
    let presence: PresenceModel
    let hider: HideDirectMessageModel
    let isResumable: Bool
    let open: () -> Void
    let toggleStar: () -> Void

    var body: some View {
        // Explicit navigation keeps the row free of a disclosure indicator. The press style
        // lets the navigation gestures cancel a press without leaving a stale highlight.
        Button(action: open) {
            ChannelRowView(row: row, presence: presence)
                .padding(.horizontal, SidebarRowMetrics.labelPaddingH)
                .padding(.vertical, SidebarRowMetrics.labelPaddingV)
        }
        .buttonStyle(.hivePress(.row, in: .rect(cornerRadius: SidebarRowMetrics.radius, style: .continuous)))
        // Both fills occupy the button's rectangle; the outer padding belongs to neither.
        .background {
            if isResumable {
                RoundedRectangle(cornerRadius: SidebarRowMetrics.radius, style: .continuous)
                    .fill(PressFeedback.fillColor.opacity(SidebarRowMetrics.opacity))
            }
        }
        .accessibilityHint(isResumable ? ChannelListView.resumeHint : "")
        .padding(SidebarRowMetrics.rowInsets)
        // Long press only: horizontal swipe actions would compete with Home navigation.
        .contextMenu {
            Button(action: toggleStar) {
                Label(
                    row.isStarred ? "Unstar" : "Star",
                    systemImage: row.isStarred ? "star.slash" : "star"
                )
            }
            .tint(.yellow)
            if row.conversation.isDirect {
                Button {
                    hider.hide(row.id)
                } label: {
                    Label("Hide", systemImage: "eye.slash")
                }
                .disabled(hider.isHiding(row.id))
            }
        }
    }
}
