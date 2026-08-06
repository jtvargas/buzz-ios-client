import BuzzKit
import SwiftUI

/// The top of the view tree: the identity gate until a key is present, then the tab bar.
/// Reads ``AppEnvironment`` from the environment so a phase change (identity accepted,
/// engine started) re-renders here automatically.
struct RootView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.scenePhase) private var scenePhase
    /// Which tab is being read. Held here rather than persisted: an app returning from the
    /// background is the same session, and an app relaunched should open where the work is.
    @State private var tab: HomeTab = .home
    @State private var pendingNotificationRoute: InAppNotificationRoute?
    @State private var visibleHomeLocation: InAppNotificationLocation?

    var body: some View {
        @Bindable var environment = environment
        phased
            // Both community sheets are presented here, above the remount boundary, so a
            // switch begun inside one does not tear the sheet off while it is still working
            // — see ``AppEnvironment/communitySheet``.
            .sheet(item: $environment.communitySheet) { sheet in
                switch sheet {
                case .switcher: CommunitySwitcherView()
                case .add: OnboardingView(isAddingCommunity: true)
                // The scanner *is* this sheet, not a step standing on the add-a-community
                // hub. Pushing it onto the hub gave it a Back button pointing at a screen
                // the reader never saw, which is the owner's report. Presented on its own
                // it carries a close button instead — see ``PairingFlowView``.
                //
                // `.preferredColorScheme(.dark)` is re-supplied here because it was the hub
                // that used to say it, and the lattice behind the viewfinder is drawn for
                // a dark screen.
                case .scan:
                    NavigationStack { PairingFlowView(isPresentedDirectly: true) }
                        .preferredColorScheme(.dark)
                case let .join(link): JoinCommunityView(initialLink: link)
                }
            }
            // Above the remount boundary for the same reason, and one more: it is opened from
            // the workspace panel, which closes itself as it opens this — see
            // ``AppEnvironment/showsSettings``.
            .sheet(isPresented: $environment.showsSettings) {
                SettingsView()
            }
            .alert(
                environment.notice?.title ?? "",
                isPresented: Binding(
                    get: { environment.notice != nil },
                    set: { if !$0 { environment.notice = nil } }
                ),
                presenting: environment.notice
            ) { _ in
                Button("OK", role: .cancel) { environment.notice = nil }
            } message: { notice in
                Text(notice.message)
            }
    }

    @ViewBuilder
    private var phased: some View {
        switch environment.phase {
        case .needsIdentity:
            OnboardingView()
        case .bootstrapping:
            ChannelBootstrapView(community: environment.communities.active?.name)
        case .running:
            if let engine = environment.engine, let store = environment.store,
               environment.workspaceMatchesActiveCommunity {
                tabs(engine: engine, store: store)
                    // The remount boundary. Every model below this — the channel list, the
                    // pushed conversations, the presence and directory observers, the
                    // navigation path — is built from one community's store and engine, and
                    // an `.id` change is what discards the lot rather than re-pointing it.
                    //
                    // Desktop reaches the same place with `<AppReady key={communityKey} />`
                    // and then has to reset fourteen module-level caches by hand, because a
                    // remount clears component state and not module state (`buzz/AGENTS.md`
                    // § Community Switching). Hive's equivalent list is
                    // ``AppEnvironment/teardownSession()``, and it is short because the
                    // per-community state here is the object graph rather than a set of
                    // singletons.
                    .id(environment.communities.activeID)
            } else {
                // `.running` with no graph, or with one belonging to the community being
                // left. Both are the same thing to look at — a community coming up — so this
                // is the screen a switch already passes through, under the incoming
                // community's name rather than the outgoing one's rows.
                ChannelBootstrapView(community: environment.communities.active?.name)
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
    private func tabs(engine: SyncEngine, store: BuzzEventStore) -> some View {
        InAppNotificationHost(
            store: store,
            engine: engine,
            selfPubkey: environment.selfPubkeyHex,
            isForeground: scenePhase == .active,
            visibleLocation: tab == .home ? visibleHomeLocation : nil
        ) { route in
            tab = .home
            pendingNotificationRoute = route
        } content: {
            TabView(selection: $tab) {
                Tab(value: HomeTab.home) {
                    ChannelListView(
                        store: store,
                        engine: engine,
                        drafts: environment.drafts,
                        selfPubkey: environment.selfPubkeyHex,
                        notificationRoute: $pendingNotificationRoute,
                        visibleNotificationLocation: $visibleHomeLocation
                    )
                } label: {
                    label(for: .home)
                }
                Tab(value: HomeTab.activity) {
                    ActivityView(
                        store: store,
                        engine: engine,
                        selfPubkey: environment.selfPubkeyHex
                    )
                } label: {
                    label(for: .activity)
                }
            }
            // A screen asked for from outside the app — Siri, Spotlight, the Shortcuts app —
            // arrives as a destination on ``AppNavigator``. This half selects the tab that
            // *holds* the screen; ``ChannelListView`` does the push and clears the request.
            //
            // Every destination today lives in the Home tab, so this is a constant rather
            // than a mapping. It becomes `destination.tab` the day one of them lives in
            // Activity — and the compiler will not remind anybody, so the day a destination
            // is added, this line is the one to look at.
            //
            // `initial: true` because a cold launch writes the request before this view
            // exists, and this is the only signal there will be. See ``AppNavigator``.
            .onChange(of: environment.navigator.pending, initial: true) { _, destination in
                guard destination != nil else { return }
                tab = .home
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

    /// The community being opened, named over the empty sidebar.
    ///
    /// It is passed in rather than derived, because this screen is also the whole of what a
    /// community *switch* looks like: the name has to be the incoming community's from the
    /// first frame, or the transition reads as the old workspace losing its rows.
    var community: String?

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
                    title: community ?? CommunityIdentity.name()
                )
        }
    }
}
