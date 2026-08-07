#if DEBUG
import BuzzKit
import Foundation
import NostrCore
import SwiftUI
import UIKit

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
/// Every event is signed by one of two ephemeral keys — taking turns, see ``authorRun`` —
/// with fixed timestamps, so a shape renders identically on every run and on every machine.
/// Heights come out of the text, not out of a hardcoded frame: the point of the shapes is
/// what a `LazyVStack` does when it has to *estimate* a row it has not measured, and a fixed
/// frame would remove the thing under test.
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
        /// Replaces the conversation with a single message linking one markdown file, so the
        /// document sheet can be opened the way a reader opens it — by pressing the link in a
        /// real message row — rather than by presenting the sheet directly.
        ///
        /// Off by default and never passed by the scroll suite, for ``links``' reason. Unlike
        /// every other shape here it reaches the network, because the sheet's whole job is to
        /// fetch: a stub would be a test of the parser, which already has one.
        var markdownDocument = false
        /// Adds one message per picture shape — tall, wide, square — so the full-screen
        /// viewer and its header can be looked at on a simulator.
        ///
        /// Off by default and never passed by the scroll suite, for `-links`' reason: a
        /// picture is height a `LazyVStack` has to estimate, and the shapes are about that
        /// estimate. This is a way to *see* the viewer, not a shape.
        var images = false
        /// One shape's name — `Tall`, `Wide`, `Square`, `Panorama`, `Column`, `Light`,
        /// `Small`, `Pair` — instead of all of them.
        ///
        /// Why a suite would want that: with every shape in one conversation, reaching the
        /// oldest of them means scrolling, and a tap issued at a conversation that is still
        /// moving lands on the row rather than on the picture — which opens a *thread*.
        /// Measured, twice. One picture per launch is a conversation that never has to be
        /// scrolled, so the tap is the only interaction in the test.
        var imageShape: String?
        /// Adds a closing message that mentions an agent *and* a person, so the two
        /// treatments can be compared in one row.
        ///
        /// Both halves are needed and neither is free: a mention needs a `p` tag before
        /// it resolves at all, and "is this pubkey an agent" is answered from the
        /// directory rather than from the message — so the fixture also has to hand the
        /// surface a ``BuzzKit/DirectorySnapshot`` saying so
        /// (``ConversationFixture/Prepared/directory``). Without that second half the row
        /// renders, resolves, and draws an ordinary `@` — a passing-looking screenshot of
        /// the thing not working.
        var agentMention = false
        /// Which message a reaction lands on, counted the way the rows are labelled, or `nil`
        /// for none. The chip arrives through the store's own observation, which is the path a
        /// peer's reaction takes and the path the reader's own takes a moment after the tap.
        var reactOn: Int?
        /// How long after launch that reaction lands, in milliseconds.
        ///
        /// Long by default, because the suite has to get the reader *parked* first and a chip
        /// that arrives during the parking would be measured against a conversation still
        /// moving. The test guards the other side of it — see
        /// `ConversationReactionScrollTests`, which fails as inconclusive rather than passing
        /// if the chip beat it.
        var reactAfter = 25_000
        /// How many pages of older history a fake relay will serve when the reader scrolls
        /// back, or `0` for a conversation whose history is only what was seeded.
        ///
        /// The shape nothing else here can make. Every other content change a shape produces
        /// arrives at the bottom or grows a row in place; this one lands *above* the reader,
        /// mid-scroll, from a round trip they triggered by reaching for it — and it is the one
        /// the scroll engine had never been measured against, because the surface could not
        /// produce it without a pager and no fixture supplied one.
        var olderPages = 0
        /// How long the fake relay takes to answer, in milliseconds. Non-zero by default: a
        /// page that lands in the same turn as the request is not the case that breaks, and
        /// arriving *during* the reader's own movement is the whole shape.
        var olderPageDelay = 120
        /// The channel's name, for the one thing in this bar that is not a scroll shape:
        /// whether the heading survives beside the trailing buttons or is moved into the
        /// `…` overflow menu. A toolbar item that does not fit is not truncated — it
        /// disappears — so the only way to see the rule hold is to give it a name long
        /// enough to break it.
        var channelName = "Fixture"

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
            options.markdownDocument = arguments.contains("-markdownDocument")
            options.images = arguments.contains("-images")
            options.agentMention = arguments.contains("-agentMention")
            options.imageShape = arguments
                .first { $0.hasPrefix("-imageShape=") }
                .map { String($0.dropFirst("-imageShape=".count)) }
            if let pages = value("olderPages") { options.olderPages = max(0, pages) }
            if let delay = value("olderPageDelay") { options.olderPageDelay = max(0, delay) }
            if let index = value("reactOn") { options.reactOn = max(0, index) }
            if let after = value("reactAfter") { options.reactAfter = max(0, after) }
            if let name = arguments.first(where: { $0.hasPrefix("-channelName=") }) {
                options.channelName = String(name.dropFirst("-channelName=".count))
            }
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

    /// How many messages in a row one author writes before the fixture hands the
    /// conversation to the next one.
    ///
    /// A conversation is people taking turns, and the surface now renders that literally:
    /// a run by one author is one block with one avatar, and the rows inside it are shorter
    /// and sit closer together than the row that opens it. A fixture signed throughout by a
    /// single key would be one unbroken block, so the shapes would never measure a row that
    /// names its author — and the suite exists to measure real rows.
    private static let authorRun = 3

    /// The messages a shape is made of, oldest first, already signed.
    ///
    /// - Parameter keys: the authors, taken in turn every ``authorRun`` messages. The
    ///   first of them opens a thread and signs the picture sampler.
    static func events(for options: Options, keys: [PrivateKey]) throws -> [NostrEvent] {
        if options.markdownSampler || options.markdownDocument {
            return [try NostrEvent.signed(
                kind: .channelMessage,
                content: options.markdownDocument ? markdownDocumentSampler : markdownSampler,
                tags: [["h", channelID]],
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                with: keys[0]
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
                // Fixed and one minute apart, so day separators and ordering are stable —
                // and, being inside the five-minute grouping window, so a run by one
                // author really does group.
                createdAt: Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + index * 60)),
                with: keys[(index / authorRun) % keys.count]
            )
            events.append(event)
            if rootID == nil, options.surface == .thread { rootID = event.id }
        }
        if options.images || options.imageShape != nil {
            for (offset, picture) in pictureSampler(only: options.imageShape).enumerated() {
                var tags: [[String]] = [["h", channelID]]
                if let rootID {
                    tags.append(["e", rootID, "", "root"])
                    tags.append(["e", rootID, "", "reply"])
                }
                events.append(try NostrEvent.signed(
                    kind: .channelMessage,
                    content: picture,
                    tags: tags,
                    createdAt: Date(
                        timeIntervalSince1970: TimeInterval(1_700_000_000 + (options.messages + offset) * 60)
                    ),
                    with: keys[0]
                ))
            }
        }
        if options.agentMention {
            var tags: [[String]] = [
                ["h", channelID],
                // A mention is a `p` tag first and text second: without these the names
                // below are ordinary words and nothing resolves.
                ["p", keys[agentKeyIndex].publicKey.hex],
                ["p", keys[personKeyIndex].publicKey.hex],
            ]
            if let rootID {
                tags.append(["e", rootID, "", "root"])
                tags.append(["e", rootID, "", "reply"])
            }
            events.append(try NostrEvent.signed(
                kind: .channelMessage,
                content: "@\(agentMentionName) can you take this one? @\(personMentionName) will review.",
                tags: tags,
                // Far past the last ordinary message, so this row is the newest whatever
                // else the shape asked for and lands where the reader is already looking.
                createdAt: Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + (options.messages + 100) * 60)),
                with: keys[personKeyIndex]
            ))
        }
        return events
    }

    // MARK: - The agent-mention shape

    /// Which of the two fixture authors stands in as the agent, and which as the person.
    /// Named rather than inlined because ``prepare(_:)`` has to describe the same two
    /// keys to the directory that ``events(for:keys:)`` tagged.
    static let agentKeyIndex = 1
    static let personKeyIndex = 0
    /// The agent's directory name. What the message's text says, so the entity scan
    /// resolves it — see ``EntityNames/aliased(_:)`` for why the directory spelling has
    /// to be registered alongside the store's.
    static let agentMentionName = "Bumble"
    /// The person's, for the same reason. Two words on purpose: a multi-word name is the
    /// case where the longest-span scan matters.
    static let personMentionName = "Ada Lovelace"

    /// The directory a shape needs on top of its events, or `.empty`.
    ///
    /// `isAgent` is not in the message and cannot be — a `p` tag says *who*, never *what*.
    /// In the app it comes from the roster's `bot` role or the relay's agent directory;
    /// here it is stated directly, which is the smallest thing that puts the surface in
    /// the state those two produce.
    static func directory(for options: Options, keys: [PrivateKey]) -> DirectorySnapshot {
        guard options.agentMention else { return .empty }
        let agent = keys[agentKeyIndex].publicKey.hex
        let person = keys[personKeyIndex].publicKey.hex
        return DirectorySnapshot(
            entities: [
                agent: DirectoryEntity(pubkey: agent, agentName: agentMentionName, isAgent: true),
                person: DirectoryEntity(pubkey: person, profileName: personMentionName, isAgent: false),
            ],
            memberPubkeysByChannel: [channelID: [agent, person]]
        )
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

    /// A message linking one markdown file — the shape a reader actually meets a document in.
    ///
    /// A public raw URL rather than a community upload: the relay refuses `.md` on upload, so
    /// a web link is the only way a document reaches a conversation today.
    private static let markdownDocumentSampler = """
    Here is a markdown file, press it to preview:

    https://raw.githubusercontent.com/mxstbr/markdown-test-file/master/TEST.md
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

    /// Signs what the composer sends and queues it in the fixture's own store.
    ///
    /// It used to refuse — the suite drove the composer's *focus*, which is what moves the
    /// keyboard, and never its send button. Where the conversation puts an author who has just
    /// sent something is a scroll question of exactly the same kind, and it cannot be asked of a
    /// sink that pretends: the whole behaviour under test is what happens when the row lands.
    ///
    /// It stops at the queue, because there is no relay here. The row stays `pending` and
    /// renders as a pending own send — the state a real device shows for the moment between
    /// pressing send and the relay's OK, which is precisely the moment the scroll decision is
    /// made in.
    struct StoringSender: MessageSending {
        let store: BuzzEventStore
        let signer: InMemorySigner

        @discardableResult
        func enqueue(
            kind: EventKind,
            content: String,
            in channel: String,
            tags: [[String]],
            maxContentBytes: Int
        ) async throws -> OutboxEntry {
            try await store.enqueue(
                kind: kind,
                content: content,
                in: channel,
                tags: tags,
                with: signer,
                maxContentBytes: maxContentBytes
            )
        }

        func retry(_ eventID: String) async throws { try await store.retry(eventID) }
        func discard(_ eventID: String) async throws { try await store.discard(eventID) }
    }

    /// Stores nothing, and answers anyway.
    ///
    /// The composer's thumbnail is decoded from the bytes on *this* device, so a fixture
    /// needs an answer rather than a blob store — which is what lets the attachment strip,
    /// the X, and the send gate be driven on a simulator with no relay in reach. The URL is
    /// deliberately unreachable: nothing in the composer fetches it, and a fixture that
    /// pointed at a real host would be a test making a network request.
    struct InertUploader: MediaUploading {
        func upload(data: Data, mimeType: String, filename _: String?) async throws -> BlobDescriptor {
            BlobDescriptor(
                url: "https://fixture.invalid/\(UUID().uuidString).jpg",
                sha256: String(UUID().uuidString.prefix(8)),
                size: data.count,
                type: mimeType,
                uploaded: 0,
                dim: "800x600"
            )
        }
    }

    /// Fetches nothing: the store is already seeded, and a thread's opening fetch exists to
    /// fill it from a relay.
    struct InertOpener: ThreadOpening {
        @discardableResult
        func openThread(root _: String) async throws -> [NostrEvent] { [] }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
#endif
