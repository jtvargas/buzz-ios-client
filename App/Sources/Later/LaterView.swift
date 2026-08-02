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
    /// The reminder that just came due, arriving from a tap on its alert.
    ///
    /// A binding rather than a value because this screen *consumes* it: it flashes the row
    /// and then clears it, which is what lets the same reminder be pointed at twice — and
    /// what stops the flash coming back every time this view redraws.
    @Binding var highlight: String?

    @Environment(\.entityNames) private var names
    @State private var tab: LaterModel.Tab = .inProgress
    @State private var rescheduling: ReminderRow?
    /// The row drawn in the accent right now, if any. Separate from ``highlight`` because
    /// the two have different lifetimes: the signal is taken once, the flash outlives it by
    /// ``flashDuration``.
    @State private var flashing: String?

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
        // `initial: true` is the whole point: this screen is usually *pushed* by the same tap
        // that sets the highlight, so by the time it exists the value has already changed and
        // there is no later change to watch for.
        .onChange(of: highlight, initial: true) { _, id in
            guard let id else { return }
            // A reminder that has come due is still pending, so it is on the first tab —
            // and the reader arriving from an alert should not have to go looking for it.
            tab = .inProgress
            highlight = nil
            flash(id)
        }
    }

    /// Draws attention to one row, briefly.
    ///
    /// Long enough to be *found* rather than merely blinked at — this is the reader arriving
    /// from a notification and asking "which one?" — and short enough that the screen settles
    /// back to being a list. The fade out is what makes it read as the screen answering the
    /// question rather than as a row that is permanently different.
    private func flash(_ id: String) {
        withAnimation(.easeOut(duration: 0.2)) { flashing = id }
        Task {
            try? await Task.sleep(for: Self.flashDuration)
            guard flashing == id else { return }
            withAnimation(.easeInOut(duration: 0.5)) { flashing = nil }
        }
    }

    /// How long the row that came due stays lit.
    static let flashDuration: Duration = .seconds(2)

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
            ScrollViewReader { proxy in
                rowList(rows)
                    // Also `initial: true`, and for the same reason as the highlight above:
                    // the flash is usually already set by the time this list is built.
                    .onChange(of: flashing, initial: true) { _, id in
                        guard let id else { return }
                        withAnimation { proxy.scrollTo(id, anchor: .center) }
                    }
            }
        }
    }

    /// The rows themselves. Lifted out of ``list`` so the `ScrollViewReader` above reads as
    /// one line rather than wrapping thirty.
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
                    reschedule: { rescheduling = row }
                )
                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                // The row that came due, lit on arrival. `0.18` is the app's own number for
                // "this is mine, lightly" — the opacity a reacted chip, a sent bubble and
                // the shortcut card's wash all draw the accent at.
                .listRowBackground(
                    flashing == row.id ? Color.hiveAccent.opacity(Self.flashOpacity) : Color.clear
                )
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

    /// The strength of that wash — see ``rowList(_:)``.
    private static let flashOpacity: CGFloat = 0.18

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
