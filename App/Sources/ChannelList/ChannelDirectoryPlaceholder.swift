import BuzzKit
import SwiftUI

/// The sidebar before the relay has said which conversations this key is in.
///
/// # Why it draws shapes and not rows
///
/// A cached channel row is a row *nothing has verified*. The owner reported deleted
/// channels appearing for a moment on every cold launch, and that is exactly what they
/// were: rows the store still held for channels the relay had since removed. The cure is
/// not a faster correction — it is refusing to draw an unverified row at all. So the
/// sidebar's conversation rows come only from a complete signed directory answer
/// (``ChannelListModel/visibleChannels``), and this is what stands in until one lands.
///
/// The official Flutter client reaches the same place from the other direction: it keeps
/// no channel cache on disk whatsoever, so it has nothing to draw while it waits and shows
/// a skeleton list — `mobile/lib/features/channels/channels_page/skeleton.dart`. Hive keeps
/// its cache, because cached history is what makes an *already open* conversation useful
/// offline; it just stops letting that cache decide what exists.
///
/// The bar widths are that client's own — `[136, 184, 112, 160, 208, 128]`, from
/// `skeleton.dart:38-41` — so the two apps' waiting states have the same rhythm.
struct ChannelDirectoryPlaceholderList: View {
    /// What the pill says. Supplied by the caller because it is the *connection's* word,
    /// not the directory's — see ``SidebarStatusPill/label(for:hasConnectedBefore:)``.
    let label: String

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(Self.barWidths.enumerated()), id: \.offset) { _, width in
                SidebarPlaceholderRow(width: width)
            }
        }
        .padding(.horizontal, 16)
        // Clear of the pill above, which is an overlay and so does not reserve height of
        // its own: at the list's own top inset the first bar lands *under* the word.
        .padding(.top, Self.pillBand)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Nothing here is a destination. Without this a press lands on the shapes and
        // reads as a row that did not respond.
        .allowsHitTesting(false)
        .overlay(alignment: .top) {
            SidebarStatusPill(label: label)
                .padding(.top, Self.pillInset)
        }
        // One element for VoiceOver: six identical bars are noise, and the pill's word is
        // the whole content.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityIdentifier(Self.accessibilityIdentifier)
    }

    static let accessibilityIdentifier = "channel-directory-connecting"

    /// The name-bar widths, in order.
    static let barWidths: [CGFloat] = [136, 184, 112, 160, 208, 128]

    /// Where the pill hangs from the top of the surface.
    static let pillInset: CGFloat = 10
    /// The height the bars must start below: the pill's inset, its own 28-pt floor, and a
    /// gap. Roughly where the shortcut cards put the first row in the real sidebar, so the
    /// two do not read as different screens.
    static let pillBand: CGFloat = 52
}

/// One waiting row, at the exact height and leading geometry of a real one
/// (``ChannelRowView``), so the rows that replace it do not move the list.
private struct SidebarPlaceholderRow: View {
    let width: CGFloat

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: AvatarShape.roundedSquare.cornerRadius(for: Self.glyphSize))
                .frame(width: Self.glyphSize, height: Self.glyphSize)
            Capsule()
                .frame(width: width, height: 12)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.quaternary)
        .padding(.vertical, 4)
        .frame(minHeight: 40)
    }

    /// ``ChannelRowView``'s own glyph size. Named here rather than read from that type
    /// because it is private there, and a placeholder that stopped matching it would move
    /// every row the instant the real ones arrived.
    private static let glyphSize: CGFloat = 30
}

/// The status pill over the waiting sidebar.
///
/// It says the same *kind* of thing as ``ConversationAccessoryCapsule`` — something is
/// under way that you did not ask for — and shares its dots and its type ramp
/// deliberately. It is not that type because that one is placed for a conversation: it
/// pins itself to the trailing edge so it covers a message's ragged right rather than its
/// first words. Over an empty list there is no text to avoid, and a trailing pill reads as
/// having come loose. If the two are ever merged, the trailing frame has to move out to
/// that type's two call sites first.
struct SidebarStatusPill: View {
    let label: String

    var body: some View {
        HStack(spacing: 6) {
            TypingDots()
            Text(label)
                .font(.hive(.caption2, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        // A floor, not a height: at an accessibility text size the label keeps its
        // intrinsic height and grows the capsule rather than being clipped in it.
        .frame(minHeight: 28)
        .glassEffect(.regular, in: .capsule)
        .transition(.opacity)
        .accessibilityHidden(true)
    }

    /// The word for the connection behind a directory that has not answered yet.
    ///
    /// Three words, and they are the Flutter client's three
    /// (`channels_page/skeleton.dart:46-54`): a socket that has never been up is
    /// *connecting*, one that was up and is not is *reconnecting*, and a socket that is up
    /// while the answer is still outstanding is *loading* — because at that point the
    /// connection is not what the reader is waiting on.
    ///
    /// ``SyncEngine/State/stopped`` sits with `.starting` rather than with the live states:
    /// at launch the engine is `.stopped` for the frames before its own start runs, and
    /// "Loading…" followed by "Connecting…" is the wrong order to read.
    static func label(for state: SyncEngine.State, hasConnectedBefore: Bool) -> String {
        switch state {
        case .starting, .stopped:
            hasConnectedBefore ? "Reconnecting…" : "Connecting…"
        case .running, .suspended:
            "Loading…"
        }
    }
}

/// The third directory surface: the relay *had* answered this launch, and a later refresh
/// did not. The list it already confirmed stays, and this says the newest state of it is
/// unknown.
///
/// A floating overlay rather than a row, so showing or removing it never changes the list's
/// row positions or scroll geometry.
struct ChannelDirectoryFallbackBanner: View {
    static let message = "Couldn’t refresh channels — showing saved conversations"

    let retry: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi.exclamationmark")
                .accessibilityHidden(true)
            Text(Self.message)
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Retry", action: retry)
                .buttonStyle(.bordered)
                .accessibilityIdentifier("channel-directory-retry")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("channel-directory-cached-fallback")
    }
}
