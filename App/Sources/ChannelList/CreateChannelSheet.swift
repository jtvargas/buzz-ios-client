import BuzzKit
import SwiftUI

/// The sheet behind the Channels heading's `+`: a name and a description, then whether the
/// room is private.
///
/// # Why two steps and not one form
///
/// The three fields are two different kinds of question. A name and a description are
/// typing — you already know the answer before the sheet opens. Visibility is a decision
/// with a consequence, and the consequence is a paragraph (below). On one page that
/// paragraph sits under a toggle nobody has looked at yet, beneath the field the keyboard
/// is covering; on its own page it is the thing being read. So: type, then decide.
///
/// # The three fields are the relay's, not a design
///
/// A create is one kind-9007 event carrying exactly `name`, `visibility`, `channel_type`
/// and an optional `about` (see ``SyncEngine/createChannel(name:about:isPrivate:)``).
/// `channel_type` is not a question anyone should be asked — this app has one kind of
/// conversation — so what is left is the three controls here, which is also the set the
/// Buzz mobile client asks for.
///
/// # What "private" costs, and why the sheet says so
///
/// A private channel is hidden from the directory and unjoinable without an invite, and
/// this app has no screen that invites anybody. So a private channel made here is a room
/// of one until somebody is added to it from Desktop. That is a real consequence of a
/// toggle that otherwise reads as a preference, so it is said under the toggle rather
/// than left to be discovered.
///
/// # Why it does not navigate
///
/// It reports the created channel and dismisses; the push happens in the sheet's
/// `onDismiss`. A push driven from inside a sheet that is dismissing races the modal
/// transition, and UIKit resolves that race by dropping the push — the same reason the
/// message-actions sheet routes its navigation through `onDismiss`.
struct CreateChannelSheet: View {
    /// Called with the new channel's id, before this dismisses.
    let created: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var model: CreateChannelModel
    @State private var step: Step = .details
    @FocusState private var nameIsFocused: Bool

    init(engine: any ChannelCreating, created: @escaping (String) -> Void) {
        _model = State(initialValue: CreateChannelModel(engine: engine))
        self.created = created
    }

    /// The two questions, in the order they are asked.
    ///
    /// Ordered by raw value rather than by a pair of hand-written transitions, so the ends
    /// close themselves: the first step has no `previous` and the last has no `next`, which
    /// is exactly what decides whether the bar says Cancel or Back, Next or Create. Adding a
    /// third step is a case, not a rewiring.
    enum Step: Int, CaseIterable {
        case details
        case visibility

        /// What the bar calls this step. Only the first keeps the sheet's own name — the
        /// second names the question instead, because by then "New Channel" is answered.
        var title: String {
            switch self {
            case .details: "New Channel"
            case .visibility: "Visibility"
            }
        }

        /// The count under the title. Two steps is short enough that a progress bar would
        /// be more furniture than information, but not so short that "there is another one
        /// after this" goes without saying.
        var subtitle: String {
            "Step \(rawValue + 1) of \(Self.allCases.count)"
        }

        var next: Step? { Step(rawValue: rawValue + 1) }
        var previous: Step? { Step(rawValue: rawValue - 1) }
    }

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                switch step {
                case .details:
                    Section {
                        TextField("Name", text: $model.name)
                            .focused($nameIsFocused)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.next)
                            .onSubmit(advance)
                        TextField("Description", text: $model.about, axis: .vertical)
                            .lineLimit(2 ... 4)
                    } footer: {
                        Text("What this space is for. Both can be changed later from Desktop.")
                    }

                case .visibility:
                    Section {
                        Toggle("Private", isOn: $model.isPrivate)
                    } footer: {
                        Text(model.isPrivate ? Self.privateFooter : Self.openFooter)
                    }
                }

                // Not scoped to the step that can produce it. A refusal only ever arrives on
                // the last one, but "the relay refused that: bad name" is about the field a
                // step back from here — so it follows the reader there rather than vanishing
                // the moment they go to act on it.
                if let failure = model.failure {
                    Section {
                        Text(failure)
                            .font(.hive(.footnote))
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(step.title)
            .navigationSubtitle(step.subtitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // Back *replaces* Cancel rather than sitting beside it, for the reason
                    // ``CreateIdentityView`` replaces the system's: two leading buttons, one
                    // of which quietly throws away an answered step, is the worse of the two
                    // problems. Leaving entirely is the swipe, which is still live here — the
                    // only thing that ever takes it away is a create already on the wire.
                    if let previous = step.previous {
                        Button("Back") { go(to: previous) }
                            .disabled(model.isSubmitting)
                    } else {
                        Button("Cancel") { dismiss() }
                            .disabled(model.isSubmitting)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if model.isSubmitting {
                        ProgressView()
                    } else if step.next != nil {
                        // The same gate as Create, deliberately: a name that canonicalises to
                        // nothing is refused at the step that asks for it, not two taps later
                        // by a button on a page that cannot show them why.
                        Button("Next", action: advance)
                            .disabled(!model.canSubmit)
                    } else {
                        Button("Create") { submit() }
                            .disabled(!model.canSubmit)
                    }
                }
            }
            // Nothing to cancel a half-finished create with, so the sheet holds still
            // while one is on the wire rather than letting a swipe strand it.
            .interactiveDismissDisabled(model.isSubmitting)
        }
        // The name is what the sheet is for, so it opens with the caret in it. Unlike a
        // conversation's composer this needs no settling delay: a sheet is presented
        // already laid out, and there is no scroll position for a keyboard to disturb.
        .task { nameIsFocused = true }
    }

    // MARK: - Moving

    /// Forward one step, if the fields on this one allow it and there is one to go to.
    ///
    /// Guarded rather than trusted, because this is also `onSubmit` — the keyboard's Next
    /// key reaches it without passing the disabled button.
    private func advance() {
        guard model.canSubmit, let next = step.next else { return }
        go(to: next)
    }

    private func go(to step: Step) {
        // The keyboard belongs to the field being left. Dropped before the move rather than
        // with it, so the step that arrives is not laid out against a keyboard on its way
        // out — and a step back lands on the fields at rest, not with the caret reclaiming
        // one the reader may not have come back for.
        nameIsFocused = false
        withAnimation(.snappy) { self.step = step }
    }

    private func submit() {
        Task {
            await model.submit()
            guard let channelID = model.created else { return }
            created(channelID)
            dismiss()
        }
    }

    static let openFooter = "Anyone in the workspace can find this channel and join it."
    static let privateFooter =
        "Hidden from the channel list, and joinable only by invitation. Adding people "
            + "isn't built here yet, so it stays yours until somebody is added from Desktop."
}

// MARK: - Presentation

extension View {
    /// Presents the new-channel sheet, and reports the created channel *after* the sheet
    /// has finished dismissing.
    ///
    /// The delay is the whole reason this is a modifier and not two lines at the call
    /// site: a navigation push started while a sheet is dismissing races the modal
    /// transition and UIKit drops it, so the id is parked here until `onDismiss` and only
    /// then handed on. The parking spot is this modifier's own state, so a navigation
    /// surface adopting the sheet does not have to hold one.
    func createChannelSheet(
        isPresented: Binding<Bool>,
        engine: any ChannelCreating,
        open: @escaping (String) -> Void
    ) -> some View {
        modifier(CreateChannelPresentation(isPresented: isPresented, engine: engine, open: open))
    }
}

private struct CreateChannelPresentation: ViewModifier {
    @Binding var isPresented: Bool
    let engine: any ChannelCreating
    let open: (String) -> Void

    /// The channel the sheet made, held from its callback until the sheet is gone.
    @State private var created: String?

    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented) {
            guard let channelID = created else { return }
            created = nil
            open(channelID)
        } content: {
            CreateChannelSheet(engine: engine) { created = $0 }
        }
    }
}
