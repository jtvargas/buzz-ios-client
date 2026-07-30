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
        case .bootstrapping:
            ChannelBootstrapView()
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
    /// Conversations and threads are read without the tab bar, which keeps the reading
    /// surface exactly the height it is today. That matters more than it looks: the scroll
    /// and keyboard behaviour of a conversation is arithmetic over the safe area, and a tab
    /// bar under the composer would change it everywhere at once.
    ///
    /// *Which* screens those are is declared once, by the view that owns each stack —
    /// ``ChannelListView/hidesTabBar`` — and not by the pushed screens themselves. Doing it
    /// per pushed view is what produced the jump the owner reported on the way back; the
    /// traces are in that property's documentation.
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

/// The returning user's first frames, while the engine is composed around their key.
///
/// It draws the same waiting sidebar the mounted workspace draws — deliberately, so this
/// hands over to ``ChannelListView`` without a visible seam. It replaced a full-screen
/// "Checking channels…" spinner that also waited on the *relay*, which made a slow network
/// into a blocked app; nothing here waits on the network.
struct ChannelBootstrapView: View {
    /// Nothing has connected yet by definition — this is the frame before the engine
    /// exists — so the word is fixed rather than read off an engine state.
    static let message = "Connecting…"

    var body: some View {
        NavigationStack {
            ChannelDirectoryPlaceholderList(label: Self.message)
                // The workspace's own heading, and not decoration: the navigation bar it
                // draws is the same top inset ``ChannelListView`` has, so the placeholder
                // rows are already where the real ones will be and the handover moves
                // nothing. It leads nowhere on purpose — there is no account to open until
                // the engine holding the identity exists.
                .conversationTitle(
                    mark: ChannelListView.communityMark,
                    title: CommunityIdentity.name()
                )
        }
    }
}
