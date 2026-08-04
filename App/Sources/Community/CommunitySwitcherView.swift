import SwiftUI
import UIKit

/// The community list, from the home heading: which communities this phone is signed in
/// to, which one is open, and the way into another.
///
/// # Why a sheet and not a rail
///
/// Desktop puts its communities in a vertical rail down the left edge, always on screen
/// (`CommunitySwitcher.tsx`). A phone has no left edge to spare — the sidebar *is* the
/// screen — so this follows the Flutter client instead, which reaches the same list from
/// the header and shows it as a sheet (`channels_page/community.dart`). The two clients
/// agree about the *content*: one row per community, the active one marked, and adding one
/// at the bottom.
struct CommunitySwitcherView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var renaming: Community?
    @State private var renamedTo = ""
    @State private var removing: Community?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(environment.communities.communities) { community in
                        row(for: community)
                    }
                }
                Section {
                    // Joining leads, because it is the one that works everywhere: a
                    // community you were invited to is closed to you until its code is
                    // redeemed, and pointing Hive at its relay without one gets a connected
                    // socket and an empty sidebar (§ ``JoinCommunityModel``).
                    Button {
                        environment.communitySheet = .join(nil)
                    } label: {
                        Label("Join with an invite", systemImage: "envelope.open")
                    }
                    // Straight onto the scanner, not onto the hub that holds it. A reader
                    // whose desktop already has Buzz open is the commonest arrival here, and
                    // the route needs nothing typed — see
                    // ``AppEnvironment/CommunitySheet/scan``. The hub is one Back away, so
                    // create and paste are still reachable from this row.
                    Button {
                        environment.communitySheet = .scan
                    } label: {
                        Label("Scan QR from Desktop", systemImage: "qrcode.viewfinder")
                    }
                } footer: {
                    Text(Self.footer)
                }
            }
            .navigationTitle("Communities")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Rename community", isPresented: renamingBinding) {
                TextField("Name", text: $renamedTo)
                Button("Cancel", role: .cancel) { renaming = nil }
                Button("Save") {
                    if let renaming {
                        environment.renameCommunity(renaming.id, to: renamedTo)
                    }
                    renaming = nil
                }
            } message: {
                Text("A name for this community on this phone. Nobody else sees it.")
            }
            .alert(
                removing.map { "Remove \($0.name)?" } ?? "Remove community?",
                isPresented: removingBinding
            ) {
                Button("Cancel", role: .cancel) { removing = nil }
                Button("Remove", role: .destructive) {
                    guard let removing else { return }
                    self.removing = nil
                    Task { await environment.removeCommunity(removing.id) }
                }
            } message: {
                Text(Self.removalWarning)
            }
        }
    }

    /// What removing a community costs, said plainly. The key is the part that cannot be
    /// undone from inside the app, so it leads.
    static let removalWarning =
        "This phone will forget the key for this community and delete the messages saved "
            + "here. Nothing is removed from the relay — you can join again with the same key."

    /// Says what a community *is*, which of the two ways in to reach for, and names the
    /// gesture that renames or removes one — there is no Edit button, so nothing else on
    /// this screen would.
    static let footer =
        "Each community is its own relay, with its own identity and its own conversations. "
            + "Use an invite unless you run the relay yourself. Long-press a row to copy "
            + "its community link; swipe to rename or remove it."

    // MARK: - Rows

    @ViewBuilder
    private func row(for community: Community) -> some View {
        let isActive = community.id == environment.communities.activeID
        Button {
            // Dismissed first: the switch remounts the workspace under this sheet, and a
            // sheet that is still up when its presenter is replaced closes without an
            // animation anyone would recognise as an answer to their tap.
            dismiss()
            Task { await environment.switchCommunity(to: community.id) }
        } label: {
            CommunitySwitcherRow(
                community: community,
                isActive: isActive,
                isSignedIn: AppEnvironment.hasStoredKey(account: community.keychainAccount),
                iconData: environment.communityStorage.iconData(for: community)
            )
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            Button("Remove", role: .destructive) { removing = community }
            Button("Rename") {
                renamedTo = community.name
                renaming = community
            }
            .tint(.hiveAccent)
        }
        .contextMenu {
            Button("Copy community link", systemImage: "link") {
                guard let origin = community.relayOrigin else { return }
                UIPasteboard.general.string = origin
            }
        }
        .listRowBackground(isActive ? Color.hiveAccent.opacity(0.10) : nil)
    }

    private var renamingBinding: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }

    private var removingBinding: Binding<Bool> {
        Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })
    }
}

/// One community in the list: its mark, its name, the relay it is, and whether it is the
/// one being read.
struct CommunitySwitcherRow: View {
    let community: Community
    let isActive: Bool
    /// Whether this phone still holds a key for it. A community signed out of stays in the
    /// list — its history is still here — and opening it leads to the gate rather than to a
    /// workspace it cannot authenticate for.
    let isSignedIn: Bool
    /// The cached relay icon, kept out of ``Community`` itself so the record remains small.
    let iconData: Data?

    var body: some View {
        HStack(spacing: 12) {
            CommunityMark(name: community.name, iconData: iconData, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(community.name)
                    .font(.hive(.body, weight: isActive ? .semibold : .regular))
                Text(subtitle)
                    .font(.hive(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if isActive {
                Image(systemName: "checkmark")
                    .font(.hiveSymbol(fixedSize: 15))
                    .foregroundStyle(Color.hiveAccent)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isActive ? [.isSelected, .isButton] : .isButton)
    }

    /// The relay under the name — the one thing that makes two communities different, and
    /// the only way to tell apart two that have been given the same label.
    private var subtitle: String {
        let host = URL(string: community.relayURLString)?.host() ?? community.relayURLString
        return isSignedIn ? host : "\(host) · signed out"
    }
}
