@testable import BuzzKit
@testable import Hive
import Foundation
import NostrCore
import Testing
import UIKit

/// Making a channel from the sidebar: what the sheet will submit, what it refuses, and
/// what it says when the relay refuses.
@Suite("Create channel", .timeLimit(.minutes(1)))
@MainActor
struct CreateChannelTests {
    /// One create as the stub saw it.
    struct Call: Equatable {
        let name: String
        let about: String?
        let isPrivate: Bool
    }

    /// A stub relay: records what it was asked for, and answers however the test wants.
    final class Creator: ChannelCreating, @unchecked Sendable {
        /// Every call, in order.
        private(set) var calls: [Call] = []
        var answer: Result<String, Error> = .success("channel-1")
        /// When true, a call suspends until ``release()`` — how a test observes the
        /// in-flight state rather than racing it.
        var holdsOpen = false
        /// True once a call is actually parked. Polled rather than assumed: releasing
        /// before the continuation exists resumes nothing and hangs the test.
        private(set) var isParked = false
        private var gate: CheckedContinuation<Void, Never>?

        func createChannel(name: String, about: String?, isPrivate: Bool) async throws -> String {
            calls.append(Call(name: name, about: about, isPrivate: isPrivate))
            if holdsOpen {
                await withCheckedContinuation { continuation in
                    gate = continuation
                    isParked = true
                }
            }
            return try answer.get()
        }

        func release() {
            gate?.resume()
            gate = nil
            isParked = false
        }
    }

    // MARK: - The submit gate

    @Test("A name that canonicalises to nothing cannot be submitted")
    func emptyNameCannotSubmit() {
        let model = CreateChannelModel(engine: Creator())
        #expect(!model.canSubmit)
        for blank in ["", "   ", "#", "# "] {
            model.name = blank
            #expect(!model.canSubmit, "'\(blank)' is not a name")
        }
        model.name = "#release-notes"
        #expect(model.canSubmit)
    }

    @Test("The fields are passed through as typed; BuzzKit owns the canonicalisation")
    func passesFieldsThrough() async {
        let creator = Creator()
        let model = CreateChannelModel(engine: creator)
        model.name = "  Release Notes "
        model.about = "What shipped"
        model.isPrivate = true

        await model.submit()

        #expect(creator.calls == [Call(name: "  Release Notes ", about: "What shipped", isPrivate: true)])
        #expect(model.created == "channel-1")
        #expect(model.failure == nil)
        #expect(!model.isSubmitting)
    }

    @Test("A second submit while one is in flight is ignored — a create is not idempotent")
    func doubleSubmitMakesOneChannel() async {
        let creator = Creator()
        creator.holdsOpen = true
        let model = CreateChannelModel(engine: creator)
        model.name = "release-notes"

        // Hold the first call open, then try to submit again while it is on the wire.
        let first = Task { await model.submit() }
        while !creator.isParked { await Task.yield() }
        #expect(model.isSubmitting)
        #expect(!model.canSubmit, "an in-flight create closes the gate")
        await model.submit()
        creator.release()
        await first.value

        #expect(creator.calls.count == 1)
        #expect(model.created == "channel-1")
    }

    // MARK: - Refusals

    @Test("A refusal is kept as a sentence and does not report a channel")
    func refusalIsReported() async {
        let creator = Creator()
        creator.answer = .failure(ChannelCreationError.rejected(.restricted("not a member")))
        let model = CreateChannelModel(engine: creator)
        model.name = "release-notes"

        await model.submit()

        #expect(model.created == nil)
        #expect(model.failure == "This workspace did not allow you to create a channel.")
        #expect(!model.isSubmitting, "a refusal frees the form to be tried again")
        #expect(model.canSubmit)
    }

    @Test("Each typed reason gets its own sentence, and an unknown one keeps the relay's words")
    func messages() {
        #expect(
            CreateChannelModel.message(for: ChannelCreationError.emptyName)
                == "A channel needs a name."
        )
        #expect(
            CreateChannelModel.message(for: ChannelCreationError.rejected(.rateLimited("slow down")))
                == "Too many channels too quickly. Try again in a moment."
        )
        #expect(
            CreateChannelModel.message(for: ChannelCreationError.rejected(.invalid("bad name")))
                == "The relay refused that: bad name"
        )
        // The unclassified arm keeps what the relay said — the case where its words are
        // worth more than ours.
        #expect(
            CreateChannelModel.message(for: ChannelCreationError.rejected(.unspecified("teapot")))
                == "The relay refused that: teapot"
        )
        #expect(
            CreateChannelModel.message(for: ChannelCreationError.publishFailed(.connectionLost))
                == "Could not reach the relay. The channel may not have been created."
        )
    }

    @Test("A failure is cleared when the next attempt starts")
    func failureClearedOnRetry() async {
        let creator = Creator()
        creator.answer = .failure(ChannelCreationError.rejected(.invalid("nope")))
        let model = CreateChannelModel(engine: creator)
        model.name = "release-notes"
        await model.submit()
        #expect(model.failure != nil)

        creator.answer = .success("channel-2")
        await model.submit()

        #expect(model.failure == nil)
        #expect(model.created == "channel-2")
    }

    // MARK: - The walk

    @Test("The walk is two steps, and both of its ends are closed")
    func stepEndsAreClosed() {
        typealias Step = CreateChannelSheet.Step
        #expect(Step.allCases == [.details, .visibility], "typing comes before deciding")
        #expect(Step.details.next == .visibility)
        #expect(Step.visibility.previous == .details)
        // The two that decide what the toolbar says. A `previous` on the first step would
        // put a Back button where Cancel is the only way out; a `next` on the last would
        // hide Create behind it.
        #expect(Step.details.previous == nil, "nothing behind the first step but Cancel")
        #expect(Step.visibility.next == nil, "nothing ahead of the last step but Create")
    }

    @Test("Every step names itself, and counts itself")
    func stepTitles() {
        #expect(CreateChannelSheet.Step.details.subtitle == "Step 1 of 2")
        #expect(CreateChannelSheet.Step.visibility.subtitle == "Step 2 of 2")
        // The count is derived, so a third step renumbers these rather than leaving two of
        // them claiming to be the last.
        for step in CreateChannelSheet.Step.allCases {
            #expect(!step.title.isEmpty)
            #expect(step.subtitle.hasSuffix("of \(CreateChannelSheet.Step.allCases.count)"))
        }
    }

    @Test("Splitting the sheet did not soften what private means")
    func visibilityFootersKeepTheirWords() {
        #expect(
            CreateChannelSheet.openFooter
                == "Anyone in the workspace can find this channel and join it."
        )
        // This one is a warning, not a description: there is no invite screen in this app,
        // so a private channel made here really is a room of one. Asserted phrase by phrase
        // because a rewrite that drops either half stops being a warning.
        #expect(CreateChannelSheet.privateFooter.contains("joinable only by invitation"))
        #expect(CreateChannelSheet.privateFooter.contains("added from Desktop"))
    }

    // MARK: - The heading

    @Test("Only Channels offers a plus, and both of the header's glyphs exist")
    func headerSymbols() {
        #expect(UIImage(systemName: "plus") != nil)
        #expect(UIImage(systemName: SidebarSectionHeader.chevronSymbol) != nil)
        // The open state is this glyph turned a half-turn, so the symbol it becomes has
        // to exist too — a rotation cannot invent one, but a future swap to it could.
        #expect(UIImage(systemName: "chevron.up") != nil)
        // The browser, not the create form: the `+` opens Browse, where joining and
        // creating both live. It said "New channel" when creating was all it did.
        #expect(SidebarSection.channels.createLabel == "Browse channels")
        // Every section has words for its plus, so a second addable section cannot
        // inherit the one Channels uses. Compared against that label rather than a
        // literal, so this keeps its meaning the next time the words change.
        for section in SidebarSection.allCases {
            #expect(!section.createLabel.isEmpty)
            #expect(section == .channels || section.createLabel != SidebarSection.channels.createLabel)
        }
    }
}
