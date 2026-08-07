import SwiftUI

/// The marker an interactive `Text` segment carries so the renderer can find it.
///
/// A `TextAttribute` and not an `AttributedStringKey`: measured in a harness, a
/// custom `AttributedString` attribute never appears in `Text.Layout`, so a renderer
/// cannot see it. `Text.customAttribute(_:)` does.
struct RichTextEntityMarker: TextAttribute {
    /// The target's URL string — the same value the flash compares against, so the
    /// renderer never has to know what kind of entity it is drawing.
    let key: String
    /// Advance sitting after this run's last glyph that belongs to the *gap*, not to
    /// the pill (see ``RichTextStyle/pillAdvance``). Only the final character of a
    /// range carries it, so a range that wraps keeps a full-width fill on every line
    /// but the last.
    var trailingAdvance: CGFloat = 0
    /// Set on the single `@` opening a mention of an agent: draw ``AgentGlyph`` in this
    /// run's place instead of its glyphs.
    ///
    /// A flag on the run rather than a substitution in the text, because the `@` has to
    /// stay in the string. It is what a copy of the message yields, what VoiceOver
    /// reads, and what the receiving client re-scans as a mention — the desktop client
    /// makes the same choice for the same reason, collapsing its `@` to zero width
    /// rather than deleting it (`.agent-mention-at-hidden`). Here it keeps its advance
    /// too, which is what pays for the glyph's space.
    var agentGlyph: Bool = false
}

/// Builds the `Text` one inline is drawn as.
enum RichTextInline {
    /// One inline as concatenated `Text`, each interactive range marked so
    /// ``RichTextEntityRenderer`` can draw its pill and carrying the `link` that
    /// makes it pressable.
    ///
    /// See ``RichTextSegments`` for why an inline is no longer a single
    /// `Text(attributedString)`.
    ///
    /// `base` is the *style* the block is set at, not a built font: see
    /// ``RichTextStyle/styled(_:base:interactive:)`` for why the weights a mention and a
    /// code span need can only be reached while the font is being built.
    static func text(_ attributed: AttributedString, base: Font.TextStyle) -> Text {
        let styled = RichTextStyle.styled(attributed, base: base, interactive: true)
        return RichTextSegments.segments(of: styled).reduce(Text("")) { text, segment in
            guard let link = segment.link else {
                return text + Text(AttributedString(styled[segment.range]))
            }
            let key = link.absoluteString
            // The range's last character is marked apart from the rest of it because
            // it carries the trailing gap's advance inside its own typographic bounds
            // — the renderer needs to know which run to take that width back out of.
            let last = styled.index(beforeCharacter: segment.range.upperBound)
            var head = segment.range.lowerBound ..< last
            // Collected rather than accumulated with `+=`: `Text` has `+` and no
            // compound form of it, so appending in place is not expressible.
            var marked: [Text] = []

            // An agent's `@` is split off ahead of the rest for the same mechanical
            // reason the last character is: a `TextRenderer` can only act on a whole
            // run, so anything needing its own treatment needs its own `Text`. Marking
            // it carries the same `key` as its siblings, so the pill still merges
            // straight through it and draws as one shape.
            if styled[segment.range].mention?.isAgent == true, !head.isEmpty {
                let at = styled.index(afterCharacter: head.lowerBound)
                marked.append(
                    Text(AttributedString(styled[head.lowerBound ..< at]))
                        .kerning(AgentGlyph.nameGap)
                        .customAttribute(RichTextEntityMarker(key: key, agentGlyph: true))
                )
                head = at ..< last
            }

            if !head.isEmpty {
                marked.append(
                    Text(AttributedString(styled[head]))
                        .customAttribute(RichTextEntityMarker(key: key))
                )
            }
            marked.append(
                Text(AttributedString(styled[last ..< segment.range.upperBound]))
                    .customAttribute(
                        RichTextEntityMarker(key: key, trailingAdvance: RichTextStyle.pillAdvance)
                    )
            )
            return marked.reduce(text) { $0 + $1 }
        }
    }
}

/// Draws the rounded tint behind every interactive range of a message, and nothing
/// else about it.
///
/// # Why a renderer rather than an attribute
///
/// `AttributedString.backgroundColor` fills a bare rectangle: no corner radius, no
/// padding, and it stops exactly at the glyphs. A `TextRenderer` gets the laid-out
/// run rects, so the pill can be grown past the text and rounded — and, because it
/// works per *line fragment*, a link that wraps draws one rounded shape on each line
/// instead of one box spanning both.
///
/// Everything else the text needs is untouched: the runs are drawn back exactly as
/// they were laid out, so Dynamic Type, wrapping, emphasis, and VoiceOver are still
/// the system's.
struct RichTextEntityRenderer: TextRenderer, Equatable {
    /// The pill currently flashing — the target's URL string, or `nil`.
    var flashing: String?
    /// Whether to use the dark-mode alphas.
    var dark: Bool

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            for pill in Self.pills(in: line) {
                context.fill(
                    Path(
                        roundedRect: pill.rect.insetBy(
                            dx: -RichTextStyle.pillPadding.width,
                            dy: -RichTextStyle.pillPadding.height
                        ),
                        cornerRadius: RichTextStyle.pillCornerRadius,
                        style: .continuous
                    ),
                    with: .color(RichTextStyle.pillFill(dark: dark, pressed: pill.key == flashing))
                )
            }
        }
        // A custom renderer owns the whole draw: nothing is drawn unless it is drawn
        // here, so the glyphs go down after the fills, in layout order.
        for line in layout {
            for run in line {
                if run[RichTextEntityMarker.self]?.agentGlyph == true {
                    Self.drawAgentGlyph(replacing: run, in: &context)
                } else {
                    context.draw(run)
                }
            }
        }
    }

    /// Draws ``AgentGlyph`` in the space `run` was laid out into, instead of `run`.
    ///
    /// The `@` is *not* drawn — that is the substitution. It keeps its place in the
    /// string and its advance in the layout, while a layout-only kern opens the requested
    /// gap before the name. A copy of the message still says `@Name`.
    ///
    /// Stroked, not filled: lucide's bot is an outline whose 2-unit stroke *is* the
    /// drawing (see ``AgentGlyph``). It takes ``RichTextStyle/tint`` directly rather
    /// than the run's own colour, which a `Text.Layout.Run` does not expose — the same
    /// value ``RichTextStyle/styled(_:base:interactive:)`` gave the run it replaces, so
    /// the two cannot drift.
    private static func drawAgentGlyph(replacing run: Text.Layout.Run, in context: inout GraphicsContext) {
        let bounds = run.typographicBounds
        var glyphRect = bounds.rect
        glyphRect.size.width = max(0, glyphRect.width - AgentGlyph.nameGap)
        let frame = AgentGlyph.frame(
            in: glyphRect,
            ascent: bounds.ascent,
            descent: bounds.descent
        )
        guard frame.width > 0 else { return }
        context.stroke(
            AgentGlyph.path(in: frame),
            with: .color(RichTextStyle.tint),
            style: AgentGlyph.strokeStyle(side: frame.width)
        )
    }

    /// One laid-out run, reduced to what the merge needs. A value rather than a
    /// `Text.Layout.Run`, which cannot be built in a test.
    struct Run {
        /// The entity this run belongs to, or `nil` for ordinary text.
        let key: String?
        /// See ``RichTextEntityMarker/trailingAdvance``.
        var trailingAdvance: CGFloat = 0
        let rect: CGRect
    }

    /// One pill: which entity it belongs to, and the glyphs it is drawn behind.
    struct Pill: Equatable {
        let key: String
        /// The glyphs' own rect — any trailing gap advance has already been taken back
        /// out, so this is what the padding is applied to.
        let rect: CGRect
    }

    /// One rect per interactive range *per line*, merged across adjacent runs.
    ///
    /// A pill has to be merged twice over, for two different reasons:
    ///
    /// - emphasis splits a range into several layout runs (`@**Ada** Lovelace` is
    ///   three), and filling each separately overlaps their padding — which showed as
    ///   brighter seams around the bold word, because the two fills compound;
    /// - a range that wraps produces runs on more than one line, and those must stay
    ///   separate, or one rounded shape would be stretched across the gap between
    ///   them.
    ///
    /// So: merge along a line, break at the end of it.
    static func pills(in line: Text.Layout.Line) -> [Pill] {
        merged(line.map { run in
            let marker = run[RichTextEntityMarker.self]
            return Run(
                key: marker?.key,
                trailingAdvance: marker?.trailingAdvance ?? 0,
                rect: run.typographicBounds.rect
            )
        })
    }

    /// The merge itself, over plain values — `Text.Layout.Line` cannot be built in a
    /// test, and this is the part with a rule in it.
    ///
    /// Only *adjacent* runs merge. Two references to the same person on one line are
    /// two pills, and unioning them would paint one shape straight through the words
    /// between them.
    static func merged(_ runs: [Run]) -> [Pill] {
        var pills: [Pill] = []
        var isContiguous = false
        for run in runs {
            guard let key = run.key else {
                isContiguous = false
                continue
            }
            // The gap's advance sits inside the run that carries it, so it is trimmed
            // before the union: it is space beside the pill, not part of the pill.
            var rect = run.rect
            rect.size.width = max(0, rect.width - run.trailingAdvance)
            if isContiguous, let last = pills.last, last.key == key {
                pills[pills.count - 1] = Pill(key: key, rect: last.rect.union(rect))
            } else {
                pills.append(Pill(key: key, rect: rect))
            }
            isContiguous = true
        }
        return pills
    }
}
