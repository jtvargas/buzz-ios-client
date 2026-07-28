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
    /// Every block, stacked, with the gap between each pair decided by
    /// ``RichTextSpacing`` rather than by one spacing for the whole stack.
    ///
    /// `spacing: 0` and a leading pad per block, because a `VStack`'s own spacing is a
    /// single number and the gap a message wants depends on *which two* blocks meet: a
    /// heading claims space above and hugs what follows, a code block or a table wants
    /// clear air on both sides, and two paragraphs of the same thought want neither.
    var full: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(message.blocks.enumerated()), id: \.offset) { index, block in
                blockView(block)
                    .padding(.top, gapAbove(index))
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

    /// The gap above the block at `index`, or nothing at all above the first one — a
    /// message's first block sits flush against the attribution line above it.
    func gapAbove(_ index: Int) -> CGFloat {
        guard index > 0 else { return 0 }
        return RichTextSpacing.gap(after: message.blocks[index - 1], before: message.blocks[index])
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
            VStack(alignment: .leading, spacing: 0) {
                // Semibold named while the font is built, not a `.fontWeight(.semibold)`
                // over it: the app's typeface drops a weight asked for by trait, so the
                // modifier this replaces drew every heading at body weight.
                RichTextInline.text(text, base: style)
                    .font(.hive(style, weight: .semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                // A rule under a level-1 heading and no other, matching upstream's
                // `autoAddDividerLineAfterH1`. It is what makes a `#` title read as the
                // top of a document rather than as a slightly larger sentence.
                if level == 1 {
                    RichRuleView()
                }
            }

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

        case let .table(table):
            RichTableView(table: table)

        case .rule:
            RichRuleView()
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
