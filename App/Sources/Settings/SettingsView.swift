import BuzzKit
import SwiftUI
import UIKit

/// The app's settings: what holds across every community on this phone.
///
/// # Why it is not part of the account screen
///
/// ``AccountView`` is about a *person* — one identity, in one community, with its own key. This
/// is about the *app*: the switches here apply whichever community is open, and most of them
/// will have nothing to do with an identity at all. Putting them there would also have hidden
/// them behind whichever community happened to be active, which is exactly the impression a
/// cross-community preference must not give.
///
/// # Adding the next setting
///
/// A row in an existing ``AccountCard``, or one more card for a new group, plus one property on
/// ``AppSettings``. Nothing here is a registry and nothing dispatches — the screen is a list of
/// switches, and it is meant to stay one.
struct SettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.entityNames) private var names
    @Environment(\.dismiss) private var dismiss

    /// Whether iOS itself will let this app raise a notification.
    ///
    /// Read on appearance rather than stored: it is changed in the system's Settings app, so a
    /// value cached here goes stale the moment somebody acts on the advice this screen gives
    /// them. `nil` until the first read, so the card does not accuse the reader of having
    /// refused something during the frame before the answer arrives.
    @State private var systemAuthorization: Bool?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    notificationsCard
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .hiveScreenGround()
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await readSystemAuthorization() }
        }
    }

    // MARK: - Notifications

    private var notificationsCard: some View {
        AccountCard(title: "Notifications", subtitle: Self.notificationsBlurb) {
            EmptyView()
        } content: {
            AccountFieldRow(label: "ON THIS PHONE") {
                Toggle("Allow notifications", isOn: notificationsBinding)
                    .font(.hive(.body))
            }
            // Only when iOS is going to ignore the switch above. Without it the screen lies:
            // the toggle reads as on, no alert ever arrives, and nothing connects the two.
            if systemAuthorization == false {
                Divider()
                systemDeniedRow
            }
        }
    }

    /// Not a plain binding to the stored property: throwing the switch has to take the alerts
    /// that are *already armed* with it, or turning notifications off leaves every reminder set
    /// before this moment still due to interrupt.
    private var notificationsBinding: Binding<Bool> {
        Binding(
            get: { environment.settings.notificationsEnabled },
            set: { isOn in
                environment.settings.notificationsEnabled = isOn
                Task { await applyNotificationSwitch(isOn) }
            }
        )
    }

    /// The way out of a permission Hive cannot ask for again. Once notifications have been
    /// refused, `requestAuthorization` returns false without prompting — this app's own page in
    /// the system Settings is the only place it can be changed.
    private var systemDeniedRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(Self.systemDeniedNote, systemImage: "exclamationmark.triangle")
                .font(.hive(.footnote))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open iOS Settings") {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            }
            .font(.hive(.footnote, weight: .medium))
            .buttonStyle(.plain)
            .foregroundStyle(.hiveAccent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Applying it

    private func readSystemAuthorization() async {
        systemAuthorization = await ReminderScheduler().isAuthorized()
    }

    /// Brings the armed alerts in line with the switch that was just thrown.
    ///
    /// **Off** cancels immediately — a switch whose effect waits on an unrelated event is not a
    /// switch, and nothing about the reminder projection changes when this one moves, so
    /// ``LaterModel``'s reconciler would not run for it.
    ///
    /// **On** re-arms from the pending reminders, which are the whole truth about what should be
    /// scheduled. ``LaterModel`` would eventually do the same on the next projection change;
    /// doing it here is what makes "back on" mean now.
    private func applyNotificationSwitch(_ isOn: Bool) async {
        let scheduler = ReminderScheduler(notificationsEnabled: { isOn })
        guard isOn else {
            await scheduler.cancelAll()
            return
        }
        // Asked at the moment it can be granted rather than at launch: the reader has just said
        // they want alerts, which is the one moment a permission prompt is not an interruption.
        // See ``ReminderScheduler/requestAuthorization()``.
        await scheduler.requestAuthorization()
        await readSystemAuthorization()

        guard let store = environment.store else { return }
        let pending = (try? store.reminders(status: .pending)) ?? []
        await scheduler.reconcile(pending: pending, authorName: { names.name(for: $0) })
    }

    // MARK: - Copy

    private static let notificationsBlurb =
        "Alerts from Hive on this phone — today, the reminders you set with Remind Me. This "
            + "applies to every community, and turning it off leaves the reminders themselves "
            + "alone: they stay in Later and still come due, they just stop interrupting you."

    private static let systemDeniedNote =
        "iOS is blocking notifications for Hive, so nothing will arrive until they are allowed "
            + "at the system level too."
}
