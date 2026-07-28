import CoreGraphics

/// How much air sits between two adjacent blocks of one message.
///
/// # Why this is a rule and not a `VStack` spacing
///
/// One number between every pair reads wrong in both directions at once. At six points
/// a heading floats between the paragraph it follows and the paragraph it introduces,
/// belonging to neither; at twelve, two paragraphs of the same thought drift apart and
/// the message reads as two messages. Typography's answer is that the gap belongs to
/// the *pair*, not to the stack: a heading takes its space from above and hugs what
/// comes after it, and a boxed block — code, a table — wants clear air on both sides so
/// its edges do not touch the sentence explaining it.
///
/// Keeping that as a function of two blocks makes it a value, which means the rule is
/// asserted in tests rather than eyeballed on a device, and there is exactly one place
/// to change when it is wrong.
enum RichTextSpacing {
    /// The ordinary paragraph-to-paragraph gap.
    static let regular = RichTextStyle.blockSpacing
    /// The gap above a heading: enough to say the section starts here.
    static let beforeHeading: CGFloat = 12
    /// The gap below a heading, tighter than ``regular`` so the heading reads as
    /// belonging to what follows it rather than sitting between two equals.
    static let afterHeading: CGFloat = 3
    /// The gap on either side of a block that draws its own frame — code and tables.
    static let aroundBoxed: CGFloat = 9
    /// The gap on either side of a thematic break, which carries its own padding
    /// already and only needs the blocks kept off it.
    static let aroundRule: CGFloat = 8

    /// The vertical gap between `previous` and `next`.
    ///
    /// Resolved most-specific-first: a heading's own claim on the space above it beats
    /// the boxed rule, so `code` followed by `## Heading` still opens a new section
    /// rather than merely closing the code block.
    static func gap(after previous: RichBlock, before next: RichBlock) -> CGFloat {
        if case .heading = next { return beforeHeading }
        if case .rule = next { return aroundRule }
        if case .rule = previous { return aroundRule }
        if case .heading = previous { return afterHeading }
        if isBoxed(next) || isBoxed(previous) { return aroundBoxed }
        return regular
    }

    /// Whether a block draws its own frame, and so wants clear space around it.
    private static func isBoxed(_ block: RichBlock) -> Bool {
        switch block {
        case .code, .table: true
        default: false
        }
    }
}
