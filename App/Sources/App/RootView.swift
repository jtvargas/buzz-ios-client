import BuzzKit
import SwiftUI

/// The top of the view tree: the identity gate until a key is present, then the tab bar.
/// Reads ``AppEnvironment`` from the environment so a phase change (identity accepted,
/// engine started) re-renders here automatically.
struct RootView: View {
    @Environment(AppEnvironment.self) private var environment
    /// Which tab is being read. Held here rather than persisted: an app returning from the
    /// background is the same session, and an app relaunched should open where the work is.
    @State private var tab: HomeTab = .home

    var body: some View {
        switch environment.phase {
        case .needsIdentity:
            OnboardingView()
        case .running:
            if let engine = environment.engine {
                tabs(engine: engine)
            } else {
                ProgressView()
            }
        case let .failed(message):
            ContentUnavailableView {
                Label("Hive couldn't start", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            }
        }
    }

    /// The two destinations.
    ///
    /// Each tab owns its own `NavigationStack` — the channel list's is inside
    /// ``ChannelListView``, with the app-wide resolvers injected above it — so a push in one
    /// tab is not a push in the other, and switching tabs does not unwind a stack.
    ///
    /// Conversations and threads hide the bar themselves (`.toolbar(.hidden, for: .tabBar)`),
    /// which keeps the reading surface exactly the height it is today. That matters more than
    /// it looks: the scroll and keyboard behaviour of a conversation is arithmetic over the
    /// safe area, and a tab bar under the composer would change it everywhere at once.
    private func tabs(engine: SyncEngine) -> some View {
        TabView(selection: $tab) {
            Tab(value: HomeTab.home) {
                ChannelListView(
                    store: environment.store,
                    engine: engine,
                    selfPubkey: environment.selfPubkeyHex
                )
            } label: {
                label(for: .home)
            }
            Tab(value: HomeTab.activity) {
                ActivityView()
            } label: {
                label(for: .activity)
            }
        }
    }

    private func label(for item: HomeTab) -> some View {
        Label(item.title, systemImage: item.symbol(isSelected: tab == item))
    }
}
