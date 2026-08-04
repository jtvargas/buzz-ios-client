import BuzzKit
import SwiftUI

/// The sheet behind the Channels heading's `+`: every channel the relay lets this
/// identity see, searchable, under **All / Joined / Archived** tabs, with Join on the
/// rows whose roster does not name you — Desktop's `ChannelBrowserDialog`, in this
/// app's clothes.
///
/// # Why it does not navigate
///
/// It reports the chosen channel and dismisses; the push happens in the sheet's
/// `onDismiss` (see ``View/browseChannelsSheet(isPresented:store:identity:engine:open:)``).
/// A push driven from inside a dismissing sheet races the modal transition and UIKit
/// drops it — the rule ``CreateChannelSheet`` and ``NewDirectMessageSheet`` already
/// follow, for the same reason.
///
/// # Join, and when it is safe to leave
///
/// Join runs ``BrowseChannelsModel/join(_:)`` and narrates its phases in place of the
/// button. The row is chosen only when that call *returns* — by then the join is
/// committed locally and the channel is hydrated enough to open. Navigating on an
/// intermediate phase would land the reader in a room whose messages are still on the
/// wire.
///
/// # Create lives in here too
///
/// Search and create sit behind one entry point, as they do on Desktop (Are.na style):
/// the toolbar's `+` presents the same sheet the Channels heading used to, through the
/// same modifier — so when that sheet grows into a wizard, this screen gets it for free.
struct BrowseChannelsView: View {
    /// Called with the channel to open, immediately before this dismisses.
    let chose: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var model: BrowseChannelsModel
    /// Whether the new-channel sheet is up, over this one.
    @State private var showsCreate = false
    private let creator: any ChannelCreating

    init(
        store: BuzzEventStore,
        identity: String?,
        joiner: any ChannelJoining,
        creator: any ChannelCreating,
        chose: @escaping (String) -> Void
    ) {
        self.init(
            model: BrowseChannelsModel(store: store, identity: identity, joiner: joiner),
            creator: creator,
            chose: chose
        )
    }

    /// The designated initialiser, taking the state directly — how a preview or fixture
    /// opens the browser already filtered or mid-join, states that otherwise exist only
    /// after somebody has typed and tapped.
    init(model: BrowseChannelsModel, creator: any ChannelCreating, chose: @escaping (String) -> Void) {
        _model = State(initialValue: model)
        self.creator = creator
        self.chose = chose
    }

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            content
                .navigationTitle("Browse Channels")
                .navigationBarTitleDisplayMode(.inline)
                .searchable(
                    text: $model.searchText,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search channels"
                )
                .safeAreaInset(edge: .top, spacing: 0) { tabs }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            showsCreate = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("New channel")
                    }
                    ToolbarItem(placement: .primaryAction) { sortMenu }
                }
        }
        // The new-channel sheet, over this one. A channel you created is one whose
        // roster already names you, so it is handed straight on to open.
        .createChannelSheet(isPresented: $showsCreate, engine: creator) { channelID in
            choose(channelID)
        }
        // A join has no cancel; the sheet holds still while one is on the wire rather
        // than letting a swipe strand its narration — the create sheet's own rule.
        .interactiveDismissDisabled(model.isJoining)
        .alert(
            "Couldn’t join the channel",
            isPresented: Binding(
                get: { model.joinFailure != nil },
                set: { if !$0 { model.joinFailure = nil } }
            )
        ) {
            Button("OK", role: .cancel) { model.joinFailure = nil }
        } message: {
            Text(model.joinFailure ?? "")
        }
        // The live re-read, cancelled with the sheet.
        .task { await model.run() }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        let rows = model.visible
        if rows.isEmpty {
            emptyState
        } else {
            List {
                ForEach(rows) { channel in
                    row(channel)
                        .listRowInsets(Self.rowInsets)
                }
            }
            .listStyle(.plain)
            .accessibilityIdentifier("browse-channels-list")
        }
    }

    /// The tab strip, pinned under the search field rather than scrolling with the rows —
    /// a filter is a standing control, not content. The backing colour is there so rows
    /// scrolled beneath it do not show through; in a sheet, `systemBackground` resolves
    /// to its elevated variant on its own.
    private var tabs: some View {
        Picker("Filter", selection: Bindable(model).tab) {
            ForEach(BrowseTab.allCases) { tab in
                Text(tab.title).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(.systemBackground))
    }

    /// Alphabetical or most-members, as a radio list behind one glyph — the toolbar has
    /// no room for words next to the `+` and Done.
    private var sortMenu: some View {
        Menu {
            Picker("Sort", selection: Bindable(model).sort) {
                ForEach(BrowseSort.allCases) { sort in
                    Text(sort.title).tag(sort)
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .accessibilityLabel("Sort")
    }

    /// One channel: the openable body on the left, the join control on the right. Two
    /// buttons in one row, each with an explicit non-default style, so the `List` gives
    /// each its own target instead of making the whole row one.
    private func row(_ channel: BrowsableChannel) -> some View {
        HStack(spacing: 12) {
            Button {
                choose(channel.id)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("#")
                            .font(.hive(.body))
                            .foregroundStyle(.secondary)
                        Text(model.displayName(of: channel))
                            .font(.hive(.body, weight: .semibold))
                            .lineLimit(1)
                        if channel.isArchived {
                            Text("Archived")
                                .font(.hive(.caption2, weight: .semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.quaternary, in: .capsule)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let detail = detailLine(for: channel) {
                        Text(detail)
                            .font(.hive(.subheadline))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            trailing(for: channel)
        }
        .frame(minHeight: 44)
        .accessibilityIdentifier("browse-channel-\(channel.id)")
    }

    /// The row's second line: how many the roster names, then what the room is for.
    /// A zero member count is *unknown* — a roster that has not landed — not an empty
    /// room, so it is left unsaid rather than stated as `0`.
    private func detailLine(for channel: BrowsableChannel) -> String? {
        var parts: [String] = []
        if channel.memberCount > 0 {
            parts.append(channel.memberCount == 1 ? "1 member" : "\(channel.memberCount) members")
        }
        if let about = channel.about ?? channel.topic,
           case let trimmed = about.trimmingCharacters(in: .whitespacesAndNewlines),
           !trimmed.isEmpty {
            parts.append(trimmed)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Join, its narration while one is running, or nothing for a row already joined —
    /// a joined channel's whole row is the way in, as it is on Desktop.
    @ViewBuilder
    private func trailing(for channel: BrowsableChannel) -> some View {
        if model.joiningChannelID == channel.id {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text(Self.label(for: model.joinProgress ?? .publishing))
                    .font(.hive(.footnote))
                    .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("browse-join-progress")
        } else if !channel.isJoined {
            Button("Join") {
                join(channel.id)
            }
            .font(.hive(.subheadline, weight: .semibold))
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            // One at a time — see ``BrowseChannelsModel/joiningChannelID``.
            .disabled(model.isJoining)
            .accessibilityIdentifier("browse-join-\(channel.id)")
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if !model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ContentUnavailableView.search(text: model.searchText)
        } else {
            ContentUnavailableView(
                Self.emptyTitle(for: model.tab),
                systemImage: "number",
                description: Text(Self.emptyDescription(for: model.tab))
            )
        }
    }

    // MARK: - Actions

    private func join(_ channelID: String) {
        Task {
            // `false` is a refusal (already in the alert) or a double tap that lost the
            // race — either way, not a state to navigate into.
            guard await model.join(channelID) else { return }
            choose(channelID)
        }
    }

    private func choose(_ channelID: String) {
        chose(channelID)
        dismiss()
    }

    // MARK: - Words

    /// What the join button narrates during each phase, named so a test can pin the
    /// narration to the phases rather than to a screenshot.
    static func label(for phase: ChannelJoinProgress) -> String {
        switch phase {
        case .publishing: "Joining…"
        case .confirming: "Confirming…"
        case .hydrating: "Loading messages…"
        case .ready: "Opening…"
        }
    }

    static func emptyTitle(for tab: BrowseTab) -> String {
        switch tab {
        case .all: "No channels yet"
        case .joined: "Nothing joined yet"
        case .archived: "No archived channels"
        }
    }

    static func emptyDescription(for tab: BrowseTab) -> String {
        switch tab {
        case .all: "Channels appear here as the relay confirms them."
        case .joined: "Channels you join appear here."
        case .archived: "Archived channels you have joined will appear here."
        }
    }

    private static let rowInsets = EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)
}

// MARK: - Presentation

extension View {
    /// Presents the channel browser, and reports the channel chosen in it *after* the
    /// sheet has finished dismissing.
    ///
    /// The delay is the reason this is a modifier and not two lines at the call site —
    /// the same race ``View/createChannelSheet(isPresented:engine:open:)`` parks its id
    /// around: a push started while a sheet is dismissing is dropped by UIKit. The
    /// parking spot is this modifier's own state, so the adopting surface holds none.
    func browseChannelsSheet(
        isPresented: Binding<Bool>,
        store: BuzzEventStore,
        identity: String?,
        engine: any ChannelJoining & ChannelCreating,
        open: @escaping (String) -> Void
    ) -> some View {
        modifier(BrowseChannelsPresentation(
            isPresented: isPresented,
            store: store,
            identity: identity,
            engine: engine,
            open: open
        ))
    }
}

private struct BrowseChannelsPresentation: ViewModifier {
    @Binding var isPresented: Bool
    let store: BuzzEventStore
    let identity: String?
    let engine: any ChannelJoining & ChannelCreating
    let open: (String) -> Void

    /// The channel the browser chose — joined, created, or already open — held from its
    /// callback until the sheet is gone.
    @State private var chosen: String?

    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented) {
            guard let channelID = chosen else { return }
            chosen = nil
            open(channelID)
        } content: {
            BrowseChannelsView(
                store: store,
                identity: identity,
                joiner: engine,
                creator: engine
            ) { chosen = $0 }
        }
    }
}
