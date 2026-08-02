import SwiftUI
import UIKit

/// The communities, over the sidebar, on the drag that brings them.
///
/// # Why this is not ``CommunitySwitcherView``
///
/// It is the same list, and deliberately the same rows — the difference is entirely in how it
/// arrives. A sheet is a thing the app presents *to* you and takes back; this is a surface you
/// move with your hand and leave where you like, which is why the community you are reading
/// stays visible in the strip beside it. Slack draws the same distinction for the same list.
///
/// The sheet is still there, and still reachable from onboarding, which has no sidebar to drag
/// on (``OnboardingView``).
struct WorkspacePanel: View {
    @Environment(AppEnvironment.self) private var environment

    let state: WorkspacePanelState
    /// The panel's width, resolved by the caller against the real screen.
    let width: CGFloat

    @State private var renaming: Community?
    @State private var renamedTo = ""
    @State private var removing: Community?

    var body: some View {
        HStack(spacing: 0) {
            panel
            // The strip the community you were reading shows through, and the target that
            // takes you back to it. Full height, because the reader aiming at "the bit of my
            // screen that is still there" is not aiming at a control.
            Color.clear
                .contentShape(.rect)
                .onTapGesture { state.setOpen(false) }
                .accessibilityLabel("Close communities")
                .accessibilityAddTraits(.isButton)
        }
        .ignoresSafeArea()
        .offset(x: -width * (1 - state.progress))
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
            Text(CommunitySwitcherView.removalWarning)
        }
    }

    // MARK: - The panel itself

    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Communities")
                .font(.hive(.title3, weight: .bold))
                .padding(.horizontal, Self.inset)
                .padding(.top, Self.headingTop)
                .padding(.bottom, Self.underHeading)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(environment.communities.communities) { community in
                        row(for: community)
                    }
                }
                .padding(.horizontal, Self.rowInset)
            }
            // The scroll edge effect at this top edge is deliberately LEFT ON, by the owner's
            // call: the band is wanted, it just cannot sit against the heading. What separates
            // them is ``underHeading``, not the effect's absence.

            Divider()
            actions
        }
        .frame(width: width, alignment: .leading)
        // The app's own grouped surface, which is what ``AccountView`` puts behind a screen
        // of cards — the panel is a screen, not a popover, so it takes a screen's background
        // rather than a material that would let the sidebar read through it.
        .background(Color(.systemGroupedBackground))
        // Rounded on the leading corners only where the panel meets the strip, the way a
        // drawer that came from off-screen would be.
        .clipShape(.rect(bottomTrailingRadius: Self.corner, topTrailingRadius: Self.corner))
        .shadow(color: .black.opacity(0.22), radius: 12, x: 2, y: 0)
    }

    /// The two ways to gain a community, at the bottom because that is where the owner asked
    /// for them and where Slack keeps the same pair. Below the list rather than inside it, so
    /// a long list scrolls under them rather than pushing them off.
    private var actions: some View {
        VStack(alignment: .leading, spacing: 0) {
            action("Join with an invite", icon: "envelope.open") {
                environment.communitySheet = .join(nil)
            }
            action("Add a relay", icon: "plus.circle") {
                environment.communitySheet = .add
            }
        }
        .padding(.horizontal, Self.inset)
        .padding(.top, 10)
        .padding(.bottom, Self.actionsBottom)
    }

    private func action(_ title: String, icon: String, run: @escaping () -> Void) -> some View {
        Button {
            // Closed first, then the sheet: a sheet presented over a panel that is still on
            // its way out arrives during an animation nobody asked for, and leaves the panel
            // open underneath it when it goes.
            state.setOpen(false)
            run()
        } label: {
            Label(title, systemImage: icon)
                .font(.hive(.body))
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.hivePress(.inline))
    }

    // MARK: - Rows

    @ViewBuilder
    private func row(for community: Community) -> some View {
        let isActive = community.id == environment.communities.activeID
        HStack(spacing: 8) {
            Button {
                // Closed without waiting: the switch tears the session down and rebuilds it
                // (``AppEnvironment/switchCommunity(to:)``), and a panel still standing over
                // that is a panel over a screen that is being replaced underneath it.
                state.setOpen(false)
                Task { await environment.switchCommunity(to: community.id) }
            } label: {
                CommunitySwitcherRow(
                    community: community,
                    isActive: isActive,
                    isSignedIn: AppEnvironment.hasStoredKey(account: community.keychainAccount),
                    iconData: environment.communityStorage.iconData(for: community)
                )
                .padding(.vertical, 10)
                .padding(.leading, 10)
            }
            .buttonStyle(.hivePress(.inline))

            // Rename, remove and copy live here rather than on a swipe. A row swipe inside a
            // panel that is itself dragged sideways is the same gesture asked to mean two
            // things, and the owner's reference draws this control instead.
            Menu {
                Button {
                    renamedTo = community.name
                    renaming = community
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                Button {
                    guard let origin = community.relayOrigin else { return }
                    UIPasteboard.general.string = origin
                } label: {
                    Label("Copy community link", systemImage: "link")
                }
                Button(role: .destructive) {
                    removing = community
                } label: {
                    Label("Remove", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.hiveSymbol(.subheadline, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .accessibilityLabel("Options for \(community.name)")
        }
        .padding(.trailing, 4)
        .background {
            if isActive {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.hiveAccent.opacity(0.12))
            }
        }
    }

    private var renamingBinding: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }

    private var removingBinding: Binding<Bool> {
        Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })
    }

    // MARK: - Metrics

    private static let inset: CGFloat = 20
    /// The rows sit a little further out than the heading, because each carries its own
    /// selected background and that background's edge is what has to line up.
    private static let rowInset: CGFloat = 10
    private static let headingTop: CGFloat = 72
    /// Between the heading and the first community. This gap is doing two jobs: the rows
    /// carry their own selected background, whose top edge was landing on the heading's
    /// baseline, and the scroll edge effect's dark band begins here. The band stays — it
    /// just has to read as the list's own edge rather than as a shadow the heading casts.
    private static let underHeading: CGFloat = 28
    private static let actionsBottom: CGFloat = 44
    private static let corner: CGFloat = 18
}

/// The scrim under the panel: the sidebar, dimmed by however far the panel is out.
///
/// Its own view so the panel can move without the scrim being re-laid out with it, and so the
/// tap that closes is declared once — the strip beside the panel and the darkness behind it
/// mean the same thing to a reader.
struct WorkspacePanelScrim: View {
    let state: WorkspacePanelState

    var body: some View {
        Color.black
            .opacity(WorkspacePanelGeometry.scrimOpacity * state.progress)
            .ignoresSafeArea()
            .allowsHitTesting(state.isOpen)
            .onTapGesture { state.setOpen(false) }
            .accessibilityHidden(true)
    }
}
