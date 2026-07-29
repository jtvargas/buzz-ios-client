import BuzzKit
import SwiftUI

/// The sheet behind the Channels heading's `+`: a name, a description, and whether the
/// room is private.
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
    @FocusState private var nameIsFocused: Bool

    init(engine: any ChannelCreating, created: @escaping (String) -> Void) {
        _model = State(initialValue: CreateChannelModel(engine: engine))
        self.created = created
    }

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $model.name)
                        .focused($nameIsFocused)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Description", text: $model.about, axis: .vertical)
                        .lineLimit(2 ... 4)
                } footer: {
                    Text("What this space is for. Both can be changed later from Desktop.")
                }

                Section {
                    Toggle("Private", isOn: $model.isPrivate)
                } footer: {
                    Text(model.isPrivate ? Self.privateFooter : Self.openFooter)
                }

                if let failure = model.failure {
                    Section {
                        Text(failure)
                            .font(.hive(.footnote))
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("New Channel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(model.isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if model.isSubmitting {
                        ProgressView()
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
