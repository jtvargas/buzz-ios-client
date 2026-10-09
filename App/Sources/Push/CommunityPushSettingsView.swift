import HivePushKit
import SwiftUI

/// The push notifications card in settings: per-community gateway URL and
/// enrollment status, gated on the relay advertising NIP-11 push capability.
///
/// Follows the same pattern as the Siri card in ``SettingsView``: an
/// ``AccountCard`` scoped to the active community, with a state indicator that
/// fades in when there is something to report. The card is only added to the
/// settings screen when ``AppEnvironment/pushCapability`` is non-nil.
struct CommunityPushSettingsView: View {
    @Environment(AppEnvironment.self) private var environment

    /// The gateway URL being edited. Initialised from the community record and
    /// committed on submit so typing does not trigger enrollment on every keystroke.
    @State private var gatewayURLField = ""
    /// The app profile field, shown only when the disclosure is open.
    @State private var appProfileField = ""
    /// Whether the advanced section is visible.
    @State private var showAdvanced = false
    /// Tracks whether the field has been modified since last commit.
    @State private var gatewayDirty = false

    var body: some View {
        AccountCard(title: "Push Notifications", subtitle: subtitle) {
            EmptyView()
        } content: {
            gatewaySection
            Divider()
            statusRow
            if showAdvanced {
                Divider()
                appProfileSection
            }
        }
        .onAppear(perform: loadFields)
        .onChange(of: environment.communities.active?.id) { _, _ in
            loadFields()
        }
    }

    // MARK: - Gateway URL

    private var gatewaySection: some View {
        AccountFieldRow(label: "GATEWAY URL") {
            VStack(alignment: .leading, spacing: 8) {
                TextField("https://gateway.example.com", text: $gatewayURLField)
                    .font(.hive(.body))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .onSubmit(commitGatewayURL)
                    .onChange(of: gatewayURLField) { old, new in
                        guard old != new else { return }
                        gatewayDirty = (new != environment.communities.active?.pushGatewayURL ?? "")
                    }

                HStack(spacing: 12) {
                    if gatewayDirty {
                        Button("Apply") { commitGatewayURL() }
                            .font(.hive(.footnote, weight: .medium))
                            .foregroundStyle(.hiveAccent)
                    }
                    if environment.communities.active?.isPushEnabled == true {
                        Button("Remove") { clearGatewayURL() }
                            .font(.hive(.footnote, weight: .medium))
                            .foregroundStyle(.red)
                    }
                    Spacer()
                    Button {
                        withAnimation(.snappy(duration: 0.25)) {
                            showAdvanced.toggle()
                        }
                    } label: {
                        Text("Advanced")
                            .font(.hive(.footnote, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Enrollment status

    @ViewBuilder
    private var statusRow: some View {
        HStack(spacing: 10) {
            switch enrollmentStatus {
            case .idle:
                Image(systemName: "circle")
                    .foregroundStyle(.secondary)
                Text("Not enrolled")
            case .checking:
                ProgressView()
                    .controlSize(.small)
                Text("Checking…")
            case .enrolling:
                ProgressView()
                    .controlSize(.small)
                Text("Enrolling…")
            case .enrolled:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Enrolled")
            case .unsupported:
                Image(systemName: "xmark.circle")
                    .foregroundStyle(.secondary)
                Text("Not supported by relay")
            case let .failed(message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .foregroundStyle(.orange)
            }
        }
        .font(.hive(.footnote))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    private var enrollmentStatus: PushEnrollmentCoordinator.Status {
        environment.pushCoordinator?.status ?? .idle
    }

    // MARK: - Advanced: App profile

    private var appProfileSection: some View {
        AccountFieldRow(label: "APP PROFILE") {
            VStack(alignment: .leading, spacing: 4) {
                TextField(PushConstants.appProfile, text: $appProfileField)
                    .font(.hive(.body))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit(commitAppProfile)
                Text("Override only if your gateway uses a custom profile.")
                    .font(.hive(.caption))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    // MARK: - Data flow

    private func loadFields() {
        let community = environment.communities.active
        gatewayURLField = community?.pushGatewayURL ?? ""
        appProfileField = community?.pushAppProfile ?? ""
        gatewayDirty = false
    }

    private func commitGatewayURL() {
        environment.setPushGatewayURL(gatewayURLField)
        gatewayDirty = false
    }

    private func clearGatewayURL() {
        gatewayURLField = ""
        environment.setPushGatewayURL(nil)
        gatewayDirty = false
    }

    private func commitAppProfile() {
        environment.setPushAppProfile(appProfileField)
    }

    // MARK: - Copy

    private var subtitle: String {
        let community = environment.communities.active?.name ?? "this community"
        return "Push notifications for \(community). Set a gateway URL to "
            + "enable real-time alerts through the relay's push service."
    }
}
