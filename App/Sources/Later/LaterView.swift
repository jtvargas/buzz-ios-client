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
    @State private var tab: LaterModel.Tab = .inProgress
    @State private var rescheduling: ReminderRow?

    var body: some View {
        VStack(spacing: 0) {
            tabs
            list
        }
        .navigationTitle("Later")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $rescheduling) { row in
            RemindMeView { due in
                rescheduling = nil
                Task { await model.snooze(row, to: due) }
            }
        }
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
                        reschedule: { rescheduling = row }
                    )
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
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
                }
            }
            .listStyle(.plain)
        }
    }

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
