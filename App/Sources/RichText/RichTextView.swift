import SwiftUI

/// How ``RichTextView`` lays a message out.
enum RichTextRenderMode {
    /// Full block layout — paragraphs, headings, quotes, code, and (nested) lists.
    case full
    /// A single truncated line — the whole message flattened, for previews and the
    /// channel-list snippet.
    case snippet
}

/// The one app-wide message renderer. Consumes a parsed, entity-resolved
/// ``RichMessage`` and lays out each block, so a mention, a channel reference, a link
/// and an email look and behave identically on every surface — channel, thread, and
/// direct message alike. Replaces the Phase-3 `MessageContentView`.
///
/// # How an interactive range works
///
/// Three parts, and each is where it is for a measured reason:
///
/// - ``RichTextStyle`` gives an entity run the accent, the weight, and the `link`
///   carrying its target. A `link` is the only run of a SwiftUI `Text` a reader can
///   press — a custom attribute is inert, and a gesture of ours costs either the
///   row's own tap or the message list's scrolling (see ``RichTextTarget``).
/// - ``RichTextInline`` builds the `Text` as concatenated segments, marking the
///   interactive ones, because a custom `AttributedString` attribute never reaches
///   `Text.Layout` and only `Text.customAttribute(_:)` does.
/// - ``RichTextEntityRenderer`` draws the rounded tint behind them, because
///   `AttributedString.backgroundColor` is a bare rectangle with no radius or
///   padding.
///
/// Everything a `Text` gives for free is still the system's: Dynamic Type, wrapping,
/// emphasis, and VoiceOver, which reads the message as one sentence. Text selection
/// is deliberately not enabled — the body's own tap opens the thread, and Copy lives
/// in the long-press menu.
struct RichTextView: View {
    @Environment(\.colorScheme) private var colorScheme
    /// Whatever the surface installed — the row's arbitrating handler in a timeline,
    /// the system's otherwise. Read here so this view can flash the pill on the way
    /// through without having to know what happens next.
    @Environment(\.openURL) private var openURL

    /// The interactive range currently flashing, by target URL string.
    @State private var flashing: String?
    /// Distinguishes one flash from the next, so a second tap's timer cannot clear
    /// the highlight the first one is still showing.
    @State private var flashToken = 0

    let message: RichMessage
    var mode: RichTextRenderMode = .full

    /// How long a pressed pill stays lit.
    ///
    /// Feedback on activation rather than on touch-down, and that is a measured
    /// decision rather than a shortcut: a touch-down highlight needs a gesture, and
    /// both places it can go cost something a reader would notice. On the text, a
    /// `DragGesture(minimumDistance: 0)` swallows the row's own tap, so plain message
    /// text stops opening the thread. On the row, beside the row's tap, the message
    /// list stops scrolling. Both verified in a harness before this was written.
    static let flashDuration: Duration = .milliseconds(220)

    /// Renders an already-parsed, already-resolved message.
    init(_ message: RichMessage, mode: RichTextRenderMode = .full) {
        self.message = message
        self.mode = mode
    }

    /// Parses and resolves `text` through the memo, then renders it. The convenience
    /// the timeline uses — a cache hit on a re-render is cheap.
    init(text: String, resolver: MentionResolver, mode: RichTextRenderMode = .full) {
        self.init(RichMessageCache.message(for: text, resolver: resolver), mode: mode)
    }

    var body: some View {
        switch mode {
        case .full: full
        case .snippet: snippet
        }
    }

    /// Lights the pressed pill, then hands the URL on to whoever the surface put in
    /// the environment.
    ///
    /// Installed *inside* the surface's own handler rather than instead of it: the
    /// row's `OpenURLAction` is what claims the tap so a link never also opens the
    /// thread, and this one only adds the flash on the way past.
    private func flash(_ url: URL) {
        flashToken += 1
        let token = flashToken
        withAnimation(.easeOut(duration: 0.08)) { flashing = url.absoluteString }
        Task { @MainActor in
            try? await Task.sleep(for: Self.flashDuration)
            guard flashToken == token else { return }
            withAnimation(.easeOut(duration: 0.18)) { flashing = nil }
        }
        openURL(url)
    }
}

// MARK: - Layout

private extension RichTextView {
    var full: some View {
        VStack(alignment: .leading, spacing: RichTextStyle.blockSpacing) {
            ForEach(Array(message.blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // One renderer for the whole message rather than one per block: it applies to
        // every `Text` in the subtree, and a block with no interactive range simply
        // has nothing for it to fill.
        .textRenderer(RichTextEntityRenderer(flashing: flashing, dark: colorScheme == .dark))
        .environment(\.openURL, OpenURLAction { url in
            flash(url)
            return .handled
        })
    }

    /// A one-line preview. Deliberately *not* interactive: the snippet sits inside a
    /// sidebar row that is itself a control, so a tappable range in it would be a
    /// second target competing for the same tap.
    var snippet: some View {
        Text(RichTextStyle.styled(message.flattenedInline(), base: .body))
            .font(.hive(.body))
            .lineLimit(1)
            .truncationMode(.tail)
    }

    @ViewBuilder
    func blockView(_ block: RichBlock) -> some View {
        switch block {
        case let .paragraph(text):
            RichTextInline.text(text, base: .body)
                .font(.hive(.body))
                .frame(maxWidth: .infinity, alignment: .leading)

        case let .heading(level, text):
            let style = Self.headingStyle(level)
            // Semibold named while the font is built, not a `.fontWeight(.semibold)`
            // over it: the app's typeface drops a weight asked for by trait, so the
            // modifier this replaces drew every heading at body weight.
            RichTextInline.text(text, base: style)
                .font(.hive(style, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .leading)

        case let .quote(text):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.secondary.opacity(0.5))
                    .frame(width: 3)
                RichTextInline.text(text, base: .body)
                    .font(.hive(.body))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .fixedSize(horizontal: false, vertical: true)

        case let .code(code, language):
            RichCodeBlock(code: code, language: language)

        case let .bulletList(items):
            RichListView(items: items, ordered: false, start: 1)

        case let .orderedList(start, items):
            RichListView(items: items, ordered: true, start: start)
        }
    }

    /// The system text style a markdown heading level is set at — a style rather than a
    /// built font, because the inline pass needs to name a weight against it.
    static func headingStyle(_ level: Int) -> Font.TextStyle {
        switch level {
        case 1: .title2
        case 2: .title3
        case 3: .headline
        default: .subheadline
        }
    }
}

// MARK: - Lists

/// A (possibly nested) list. Renders each item's marker + content, then recurses
/// into that item's child lists indented one level deeper.
private struct RichListView: View {
    let items: [RichListItem]
    let ordered: Bool
    let start: Int
    var depth: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                VStack(alignment: .leading, spacing: 2) {
                    RichListRow(marker: marker(index), content: item.content)
                    ForEach(Array(item.children.enumerated()), id: \.offset) { _, child in
                        childList(child)
                    }
                }
            }
        }
        .padding(.leading, depth == 0 ? 0 : RichTextStyle.nestedIndent)
    }

    private func marker(_ index: Int) -> String {
        ordered ? "\(start + index)." : "•"
    }

    @ViewBuilder
    private func childList(_ block: RichBlock) -> some View {
        switch block {
        case let .bulletList(items):
            RichListView(items: items, ordered: false, start: 1, depth: depth + 1)
        case let .orderedList(start, items):
            RichListView(items: items, ordered: true, start: start, depth: depth + 1)
        default:
            EmptyView() // children are only ever nested lists
        }
    }
}

/// One list item's row: a fixed-width marker column so wrapped item text stays
/// aligned under the first line rather than under the marker.
private struct RichListRow: View {
    let marker: String
    let content: AttributedString

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(marker)
                .font(.hive(.body))
                .foregroundStyle(.secondary)
                .frame(minWidth: 16, alignment: .trailing)
            RichTextInline.text(content, base: .body)
                .font(.hive(.body))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Code

/// A fenced code block: monospaced, on a subtle fill, its raw text never inline- or
/// entity-parsed. Long lines wrap rather than scroll, so the block never fights the
/// timeline's vertical scroll.
private struct RichCodeBlock: View {
    let code: String
    let language: String?

    var body: some View {
        Text(code)
            // Still the system's monospaced face, and now said so explicitly: Lato is
            // not a code face and has no fixed-width member for `.monospaced()` to find.
            .font(.hiveMono(.callout))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.12))
            )
            .overlay(alignment: .topTrailing) {
                if let language, !language.isEmpty {
                    Text(language)
                        .font(.hive(.caption2))
                        .foregroundStyle(.secondary)
                        .padding(6)
                        .accessibilityHidden(true)
                }
            }
    }
}
