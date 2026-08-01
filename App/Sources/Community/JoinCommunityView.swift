import BuzzKit
import SwiftUI

/// Joining a community by invitation.
///
/// One screen rather than a wizard, because the reader is making one decision — *do I want
/// to be in this* — and the things they need in order to make it (which relay, what its
/// terms are, which identity they will be there) all belong in front of them at once. The
/// Flutter client's sheet is the same shape (`invite_join_sheet.dart`), and puts the relay
/// host in a box of its own for the same reason: the host is the only part of an invite
/// that says where you are actually going.
struct JoinCommunityView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    /// The invite this screen opened with, when it was opened by one — a `buzz://join`
    /// handoff from the relay's own web page.
    let initialLink: InviteLink?

    /// Built in ``body``'s task rather than in an initialiser, because it needs the
    /// environment and `@State` is initialised before any environment is readable.
    @State private var model: JoinCommunityModel?

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    form(model)
                } else {
                    // At most one frame, before the task below runs.
                    Color.clear
                }
            }
            .navigationTitle("Join a community")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .task {
            guard model == nil else { return }
            model = JoinCommunityModel(environment: environment, initialLink: initialLink)
        }
    }

    // MARK: - The screen

    @ViewBuilder
    private func form(_ model: JoinCommunityModel) -> some View {
        @Bindable var model = model
        Form {
            linkSection(text: $model.linkText, note: model.linkNote)
            if let link = model.link {
                destinationSection(link: link, isReadingPolicy: model.isReadingPolicy)
                if let community = model.alreadyJoined {
                    alreadyJoinedSection(community)
                } else {
                    if let policy = model.policy, link.policyReceipt == nil {
                        policySection(policy: policy, link: link, ageConfirmed: $model.ageConfirmed)
                    }
                    identitySection(identity: $model.identity, nsec: $model.nsec)
                }
            }
            if let error = model.error {
                Section {
                    Text(error)
                        .font(.hive(.footnote))
                        .foregroundStyle(.red)
                        .accessibilityLabel("Error: \(error)")
                }
            }
            Section {
                Button {
                    // Unstructured on purpose: a successful join closes this sheet, and a
                    // `.task`-owned child would be cancelled by that teardown while the
                    // engine it started was still coming up.
                    Task { await model.submit() }
                } label: {
                    HStack {
                        Spacer()
                        if model.step == .joining {
                            ProgressView().controlSize(.small).padding(.trailing, 6)
                        }
                        Text(model.actionTitle)
                        Spacer()
                    }
                }
                .disabled(!model.canJoin || model.step == .joining)
            }
        }
        .disabled(model.step == .joining)
    }

    private func linkSection(text: Binding<String>, note: String) -> some View {
        Section {
            TextField("https://relay.example/invite/…", text: text, axis: .vertical)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .lineLimit(1 ... 3)
            PasteButton(payloadType: String.self) { strings in
                guard let pasted = strings.first else { return }
                Task { @MainActor in text.wrappedValue = pasted }
            }
            .labelStyle(.titleAndIcon)
        } header: {
            Text("INVITE LINK")
        } footer: {
            // The footer carries the diagnosis rather than the error section: text that has
            // not resolved into an invitation is not a failure, and the sentence belongs
            // under the field it is about.
            Text(note)
        }
    }

    /// Where this link goes. The host leads and is monospaced, because it is the one field
    /// on this screen a reader is expected to actually check.
    private func destinationSection(link: InviteLink, isReadingPolicy: Bool) -> some View {
        Section {
            LabeledContent("Relay") {
                Text(link.host)
                    .font(.hiveMono(.callout))
                    .textSelection(.enabled)
            }
            if isReadingPolicy {
                LabeledContent("Terms") { ProgressView().controlSize(.small) }
            }
        } header: {
            Text("YOU'RE JOINING")
        }
    }

    private func alreadyJoinedSection(_ community: Community) -> some View {
        Section {
            Label(
                "You're already in \(community.name) on this phone.",
                systemImage: "checkmark.circle"
            )
            .font(.hive(.subheadline))
        }
    }

    /// The operator's terms, and the acceptance the relay will demand proof of.
    ///
    /// The documents open in the browser rather than being rendered here: the relay serves
    /// each as a real page (`/api/join-policy/terms`), Desktop hands them to the system
    /// browser for the same reason (`invites.ts:106-113`), and a legal document read inside
    /// a modal sheet with nowhere to go back to is worse than one read in Safari.
    ///
    /// Not shown at all when the link already carries a receipt: that acceptance was made
    /// in a browser, on the relay's own page, and asking for it twice would suggest the
    /// first one did not count.
    private func policySection(
        policy: JoinPolicy,
        link: InviteLink,
        ageConfirmed: Binding<Bool>
    ) -> some View {
        Section {
            if policy.termsMarkdown != nil {
                Button("Terms of Service") { open(document: "terms", of: link) }
            }
            if policy.privacyMarkdown != nil {
                Button("Privacy Policy") { open(document: "privacy", of: link) }
            }
            if policy.ageAttestationRequired {
                Toggle("I meet this community's minimum age", isOn: ageConfirmed)
            }
        } header: {
            Text("THIS COMMUNITY'S TERMS")
        } footer: {
            Text(
                policy.ageAttestationRequired
                    ? "Joining records that you accepted these terms and made this statement."
                    : "Joining records that you accepted these terms."
            )
        }
    }

    private func identitySection(
        identity: Binding<JoinCommunityModel.Identity>,
        nsec: Binding<String>
    ) -> some View {
        Section {
            Picker("Identity", selection: identity) {
                ForEach(JoinCommunityModel.Identity.allCases) { choice in
                    Text(choice.label).tag(choice)
                }
            }
            .pickerStyle(.segmented)
            if identity.wrappedValue == .existing {
                SecureField("nsec1…", text: nsec)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
        } header: {
            Text("IDENTITY")
        } footer: {
            Text(
                identity.wrappedValue == .new
                    ? JoinCommunityModel.newIdentityWarning
                    : JoinCommunityModel.existingIdentityBlurb
            )
        }
    }

    /// Opens one of the relay's policy pages in the browser.
    private func open(document: String, of link: InviteLink) {
        let scheme = link.relayURLString.hasPrefix("wss://") ? "https" : "http"
        guard let url = URL(string: "\(scheme)://\(link.host)/api/join-policy/\(document)") else {
            return
        }
        openURL(url)
    }
}
