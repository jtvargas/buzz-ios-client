import SwiftUI

/// The list of times a reminder can be set for.
///
/// Pushed onto whatever stack presents it rather than presented as a second sheet — the
/// same rule the emoji picker follows in ``MessageActionsSheet``, and for the same reason:
/// a modal presented from inside a modal races the first one's dismissal.
struct RemindMeView: View {
    /// What to do with the chosen instant. The caller decides whether that is a new
    /// reminder or a new time for one that exists.
    let onPick: (Date) -> Void

    @Environment(\.calendar) private var calendar

    var body: some View {
        List {
            Section {
                ForEach(ReminderPreset.all) { preset in
                    row(preset)
                }
            } footer: {
                Text("Reminders sync across your devices. The alert is scheduled on this one.")
                    .font(.hive(.footnote))
            }
        }
        .listStyle(.insetGrouped)
        // No ground modifier, deliberately, and none before #124 either — which matters more
        // here than anywhere, because this view is pushed onto *two* stacks at two different
        // elevations: the Later tab, and ``MessageActionsSheet``'s own stack inside a modal.
        // The `List` resolves its page and its cards against whichever one it lands in, so
        // one view is right in both without either presenter having to say so. A colour named
        // out here would have to pick one of them and be wrong in the other.
        // See ``View/hiveSheetGround()``.
        .navigationTitle("Remind me")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ preset: ReminderPreset) -> some View {
        Button {
            HiveHaptics.play(.send)
            // Resolved at the tap, not when the list was drawn: a sheet left open for ten
            // minutes must not set a reminder ten minutes stale.
            onPick(preset.due(Date(), calendar))
        } label: {
            HStack(spacing: 12) {
                Image(systemName: preset.symbol)
                    .font(.hiveSymbol(.body))
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                Text(preset.label)
                    .font(.hive(.body))
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Text(Self.dueLabel(preset.due(Date(), calendar), calendar: calendar))
                    .font(.hive(.footnote))
                    .foregroundStyle(.tertiary)
            }
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    /// The clock time a preset lands on, so "In 3 hours" can be checked against a watch
    /// before it is chosen.
    static func dueLabel(_ due: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = .autoupdatingCurrent
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = calendar.isDateInToday(due) ? "h:mm a" : "E h:mm a"
        return formatter.string(from: due)
    }
}
