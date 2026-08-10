import BuzzKit
import SwiftUI

/// Later: the messages this reader asked to be reminded about.
///
/// Three tabs over one table, named for what a reader is doing rather than for the status
/// underneath: **In Progress** is `pending`, **Archived** is `cancelled`, **Completed** is
/// `done`. A row carries where the message came from, when the reminder is due, who wrote
/// it and what it said — and the two things worth doing to it without opening it.
struct LaterView: View {
    let model: LaterModel
    /// Resolves a channel id to its name for the row's first line. Passed in because the
    /// conversation list already holds the directory this would otherwise re-query.
    let channelName: (String) -> String
    /// Opens the message a reminder points at.
    let openTarget: (ReminderTarget) -> Void

    @Environment(\.entityNames) private var names
    @Environment(\.pushRoute) private var pushRoute
    @State private var tab: LaterModel.Tab = .inProgress

    var body: some View {
        VStack(spacing: 0) {
            tabs
            list
        }
        // On the whole screen rather than on ``rowList``: the segmented strip above the list
        // and the three empty states that replace it are outside that view.
        .hiveScreenGround()
        .navigationTitle("Later")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var tabs: some View {
        Picker("Filter", selection: $tab) {
            ForEach(LaterModel.Tab.allCases) { tab in
                Text(label(for: tab)).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// The count rides on In Progress only. On the other two it would be a number nobody
    /// is waiting on, and Slack shows it in the same one place.
    private func label(for tab: LaterModel.Tab) -> String {
        guard tab == .inProgress, !model.pending.isEmpty else { return tab.rawValue }
        return "\(tab.rawValue) \(model.pending.count)"
    }

    @ViewBuilder
    private var list: some View {
        let rows = model.rows(for: tab)
        if rows.isEmpty {
            emptyState
        } else {
            rowList(rows)
        }
    }

    /// The rows themselves. Lifted out of ``list`` so that branch reads as two lines rather
    /// than wrapping thirty.
    private func rowList(_ rows: [ReminderRow]) -> some View {
        List {
            ForEach(rows) { row in
                LaterRow(
                    row: row,
                    channelName: row.target.map { channelName($0.channelID) } ?? "",
                    authorName: row.target.map { names.name(for: $0.authorPubkey) } ?? "",
                    authorPicture: row.target.flatMap { names.picture(for: $0.authorPubkey) },
                    authorInitials: row.target.map { names.initials(for: $0.authorPubkey) } ?? "?",
                    isPending: tab == .inProgress,
                    open: { if let target = row.target { openTarget(target) } },
                    complete: { Task { await model.complete(row) } },
                    reschedule: { pushRoute?(.rescheduling(row)) }
                )
                .listRowInsets(
                    EdgeInsets(
                        top: Self.rowPadding,
                        leading: MessageRowMetrics.rowLeading,
                        bottom: Self.rowPadding,
                        trailing: MessageRowMetrics.rowLeading
                    )
                )
                // Full-bleed, as Slack's are. The default separator starts at the row's
                // leading inset, which on a row whose content is a message reads as a rule
                // hung off the avatar rather than as the line between two entries.
                .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                // Archiving is the destructive-looking action, so it is a swipe rather
                // than a third button competing with the two that matter.
                .swipeActions(edge: .trailing) {
                    if tab != .archived {
                        Button("Archive", systemImage: "archivebox") {
                            Task { await model.archive(row) }
                        }
                        .tint(.orange)
                    }
                }
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
    }

    /// The air above and below a row. Enough that a row reads as an entry with a message in
    /// it rather than as a line in a table — its content is three stacked parts, and Slack
    /// gives the same stack about this much.
    private static let rowPadding: CGFloat = 14

    @ViewBuilder
    private var emptyState: some View {
        switch tab {
        case .inProgress:
            ContentUnavailableView(
                "Nothing saved for later",
                systemImage: "clock.badge",
                description: Text("Hold a message and choose Remind Me to save it here.")
            )
        case .archived:
            ContentUnavailableView(
                "Nothing archived",
                systemImage: "archivebox",
                description: Text("Reminders you dismiss without completing land here.")
            )
        case .completed:
            ContentUnavailableView(
                "Nothing completed yet",
                systemImage: "checkmark.circle",
                description: Text("Reminders you finish land here.")
            )
        }
    }
}
