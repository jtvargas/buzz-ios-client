#if DEBUG
import BuzzKit
import Foundation
import NostrCore
import SwiftUI

/// A conversation of a requested *shape*, opened straight from a launch argument, so a UI
/// test can drive the real ``ThreadView`` and ``ChannelTimelineView`` without a relay.
///
/// # Why this exists
///
/// Three scroll defects shipped in a row — `#49`, `#50`, `#52` — and the owner found every
/// one of them on a device. Nothing in CI could catch them, because the only thing that ever
/// detected them was a set of thirteen conversation *shapes* (how many messages, how tall the
/// tallest, where it sits) driven through a real keyboard, and reaching a conversation in this
/// app means reaching a `SyncEngine`, which means a socket. So the shapes lived outside the
/// repo and rendered a copy of the surface, which is free to drift from the surface.
///
/// This is the missing launch path. `-fixtureConversation thread` opens the real thread screen
/// against a throwaway store seeded with signed events.
///
/// # What it is not
///
/// It is not a preview and not a mock of the view. The rows, the scaffold, the composer, the
/// keyboard arithmetic and the scroll corrections are all the shipping code; only the store's
/// contents and the send/typing sinks are substituted. And it is compiled out of release
/// entirely — the whole file is inside `#if DEBUG`.
///
/// # Determinism
///
/// Every event is signed by one ephemeral key with fixed timestamps, so a shape renders
/// identically on every run and on every machine. Heights come out of the text, not out of a
/// hardcoded frame: the point of the shapes is what a `LazyVStack` does when it has to
/// *estimate* a row it has not measured, and a fixed frame would remove the thing under test.
enum ConversationFixture {
    /// Which conversation screen a shape opens.
    enum Surface: String {
        case thread
        case channel
    }

    /// Which surface to open, and the shape to open it with.
    struct Options: Equatable {
        var surface: Surface = .thread
        /// How many messages the conversation holds.
        var messages = 6
        /// How many lines the tall message gets, or `0` for none. The defect this suite
        /// exists for only appears when a row is taller than the viewport.
        var longLines = 0
        /// Which message from the end is the tall one. `1` is the newest.
        var longFromEnd = 1
        /// Widens the spread of ordinary row heights. A conversation is not a stack of equal
        /// boxes, and how wrong the stack's *average* is turns on that spread.
        var spread = false
        /// How many messages the first synchronous read finds, with the rest arriving after
        /// the first layout — a thread whose replies land a relay round trip later.
        var primed = Int.max
        /// Hangs a set of links off the newest message, so the link cards can be looked at.
        ///
        /// Off by default and never passed by the scroll suite, deliberately: a card adds
        /// height to a row, and the shapes are about what a `LazyVStack` estimates. This is
        /// a way to *see* the cards on a simulator, not a shape.
        var links = false
        /// Replaces the ordinary fixture conversation with a single markdown message that
        /// exercises the inline renderer. It is a visual regression sampler, not a scroll
        /// shape, so it remains inert unless explicitly requested at launch.
        var markdownSampler = false

        /// Parses the arguments the test launched us with, or `nil` for a normal run.
        ///
        /// Deliberately tolerant: an unrecognised value falls back to the default rather than
        /// trapping, because a fixture that crashes on a typo reads in CI as a product failure.
        static func parse(_ arguments: [String]) -> Options? {
            guard let index = arguments.firstIndex(of: "-fixtureConversation") else { return nil }
            var options = Options()
            if let raw = arguments[safe: index + 1], let surface = Surface(rawValue: raw) {
                options.surface = surface
            }
            func value(_ key: String) -> Int? {
                arguments
                    .first { $0.hasPrefix("-\(key)=") }
                    .flatMap { Int($0.dropFirst(key.count + 2)) }
            }
            if let messages = value("messages") { options.messages = max(1, messages) }
            if let lines = value("longLines") { options.longLines = max(0, lines) }
            if let from = value("longFromEnd") { options.longFromEnd = max(1, from) }
            if let primed = value("primed") { options.primed = max(1, primed) }
            options.spread = arguments.contains("-spread")
            options.links = arguments.contains("-links")
            options.markdownSampler = arguments.contains("-markdownSampler")
            return options
        }
    }

    /// The channel every fixture conversation lives in.
    static let channelID = "fixture-channel"

    /// The shape this launch asked for, if any.
    static var requested: Options? {
        Options.parse(ProcessInfo.processInfo.arguments)
    }

    // MARK: - Content

    /// The messages a shape is made of, oldest first, already signed.
    ///
    /// - Parameter root: when non-nil, every message after the first carries an `e` tag
    ///   marking it a reply to `root` — which is what makes the set a thread.
    static func events(for options: Options, key: PrivateKey) throws -> [NostrEvent] {
        if options.markdownSampler {
            return [try NostrEvent.signed(
                kind: .channelMessage,
                content: markdownSampler,
                tags: [["h", channelID]],
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                with: key
            )]
        }
        var events: [NostrEvent] = []
        var rootID: String?
        for index in 0 ..< options.messages {
            let fromEnd = options.messages - index
            let lines = fromEnd == options.longFromEnd && options.longLines > 0
                ? options.longLines
                : ordinaryLines(index: index, spread: options.spread)
            var tags: [[String]] = [["h", channelID]]
            if let rootID {
                // Both NIP-10 markers, and both pointing at the root. A `root` marker alone
                // leaves `NostrEvent.threadReference` with no parent, the projector writes no
                // `thread` row, and the reply is invisible to `store.thread(root:)` — measured
                // the hard way: the first version of this fixture rendered the opener and
                // nothing else. A Buzz thread is flat, so replying to the root is also true.
                tags.append(["e", rootID, "", "root"])
                tags.append(["e", rootID, "", "reply"])
            }
            let event = try NostrEvent.signed(
                kind: .channelMessage,
                content: body(index: index, lines: lines, links: options.links && fromEnd == 1),
                tags: tags,
                // Fixed and one minute apart, so day separators and ordering are stable.
                createdAt: Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + index * 60)),
                with: key
            )
            events.append(event)
            if rootID == nil, options.surface == .thread { rootID = event.id }
        }
        return events
    }

    /// Deterministic and deliberately uneven: a real conversation runs from a one-word reply
    /// to a pasted stack trace, and a stack of near-identical rows cannot express the
    /// estimation error this suite is about.
    private static func ordinaryLines(index: Int, spread: Bool) -> Int {
        1 + (index * 7) % (spread ? 25 : 9)
    }

    private static func body(index: Int, lines: Int, links: Bool = false) -> String {
        let text = (0 ..< lines)
            .map { line in
                line == 0
                    ? "Message \(index) line 0"
                    : "Message \(index) line \(line) — filler text to give this row a real measured height."
            }
            .joined(separator: "\n")
        return links ? text + "\n\n" + linkSampler : text
    }

    /// One of each card the renderer can draw: a provider with a real name, an authored
    /// label over a provider, an ordinary URL with a path, and a bare domain.
    private static let linkSampler = """
    https://github.com/jtvargas/buzz-ios-client/pull/61
    [the scroll fix](https://linear.app/acme/issue/ENG-1421/fix-the-scroll)
    https://developer.apple.com/documentation/swiftui/scrollposition
    https://example.com
    """

    // swiftlint:disable line_length
    /// The production-like message used to inspect inline markdown treatment by eye. Launch
    /// with `-fixtureConversation thread -markdownSampler`; without both fixture arguments the
    /// normal application path remains unchanged.
    private static let markdownSampler = """
    ## On the review itself

    You did the two things I asked for and one I did not. **The query-text diff is the one I did not think to ask for and would have wanted most** — showing that the CTE bodies and the entire outer `SELECT`/`GROUP BY`/`HAVING`/`ORDER BY` are byte-identical reduces the whole equivalence question to a single reachability claim about `candidate`, which your witness argument already closes generally. That is a smaller thing to be right about than 22 sampled scenarios, and it is stronger.

    And you built the plan against a schema pulled out of `Schema.swift` rather than reasoning from the source. This repo's rule is that an index claim is not a claim until the planner is asked — you asked it, twice, under two different statistics states so a missing-`ANALYZE` artifact could not explain the join order.

    A line with *italic*, ***bold italic***, ~~struck~~, and `**bold inside code**` to prove composition.

    ---

    ### The blocks that draw their own frame

    | Gate | Runs on | Cost |
    |---|---|---:|
    | SwiftLint | every PR | 40s |
    | App tests | every PR | 9m |

    > A quote, so the rule above and the fence below have something with an edge on both sides of them.

    ```swift
    func gap(after previous: RichBlock, before next: RichBlock) -> CGFloat {
        RichTextSpacing.gap(after: previous, before: next)
    }
    ```

    - A bullet, to see a list against a fence
    - And a second one

    `.scratch/eqp-81/` noted. Nothing further from you on #81.
    """
    // swiftlint:enable line_length

    // MARK: - Store

    /// A throwaway store, never the app's own.
    ///
    /// A UI test that seeded the real `store.sqlite` would destroy whatever the developer or
    /// the runner had in it, and two tests running back to back would see each other's
    /// messages. The path carries the process id so even a re-launch within one test run is
    /// clean.
    static func makeStore() throws -> BuzzEventStore {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("hive-fixture-\(ProcessInfo.processInfo.processIdentifier).sqlite")
            .path
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: path + suffix)
        }
        return try BuzzEventStore(path: path)
    }

    // MARK: - Substituted sinks

    /// Sends nothing. The suite drives the composer's *focus* — which is what moves the
    /// keyboard and the scroll view — and never its send button, so a sink that refuses is
    /// more honest than one that pretends.
    struct InertSender: MessageSending {
        @discardableResult
        func enqueue(
            kind _: EventKind,
            content _: String,
            in _: String,
            tags _: [[String]],
            maxContentBytes _: Int
        ) async throws -> OutboxEntry {
            throw FixtureSendUnavailable()
        }

        func retry(_: String) async throws { throw FixtureSendUnavailable() }
        func discard(_: String) async throws { throw FixtureSendUnavailable() }
    }

    /// Fetches nothing: the store is already seeded, and a thread's opening fetch exists to
    /// fill it from a relay.
    struct InertOpener: ThreadOpening {
        @discardableResult
        func openThread(root _: String) async throws -> [NostrEvent] { [] }
    }
}

/// Thrown by ``ConversationFixture/InertSender``: the suite drives the composer's focus, never
/// its send button.
private struct FixtureSendUnavailable: Error {}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
#endif
