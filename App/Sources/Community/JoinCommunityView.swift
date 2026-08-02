import BuzzKit
import SwiftUI

/// Joining a community by invitation, in two steps.
///
/// # Why two, when this was deliberately one
///
/// It was one screen on the argument that the reader is making a single decision — *do I want
/// to be in this* — and that everything they need in order to make it belongs in front of them
/// at once. That argument stopped being true when the screen grew a third thing on it. It now
/// carries the community and its terms, a name, and a choice of key, and only the first is the
/// decision; the other two are consequences of having already made it. Asking somebody which
/// identity they will use before they have agreed to join is asking them to furnish a room they
/// have not agreed to rent.
///
/// So: **the community and its terms**, then **who you will be in it**. Desktop draws the line
/// in the same place — its invite step ends on `Next` (`InviteRedeemForm.tsx:317`) and the
/// profile and key steps follow (`CommunityOnboardingFlow.tsx`). The split is § ``JoinCommunityModel/Step``;
/// this file only draws it.
///
/// The relay host stays in a box of its own under the field, as the Flutter client's sheet has
/// it (`invite_join_sheet.dart`), because the host is the only part of an invite that says
/// where you are actually going.
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

    /// Which field holds the keyboard, so the accessory below it can give it back.
    @FocusState private var focused: Field?

    /// The fields on both steps. One type across the two, because the accessory that dismisses
    /// the keyboard is one control and does not care which step raised it.
    private enum Field: Hashable {
        case link
        case name
        case nsec
    }

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
                    if let model, model.canGoBack {
                        // Back rather than Cancel, in the place a reader already looks for it.
                        // Cancelling from here is the sheet's own downward drag, which is
                        // unambiguous; a Back that also abandoned the join would not be.
                        Button("Back") {
                            withAnimation(.snappy) { model.goBack() }
                        }
                        .disabled(model.step == .joining)
                    } else {
                        Button("Cancel") { dismiss() }
                    }
                }
                // The button that hands the keyboard back.
                //
                // Asked for by name: on a screen whose fields sit above content worth reading,
                // a keyboard that can only be dismissed by dragging fights the scroll. This is
                // the plain `.keyboard` placement, which is *not* the thing
                // ``ConversationScaffold`` forbids — that prohibition is about the conversation
                // shell, which does its own keyboard avoidance and would double-count. A
                // `Form` on a sheet uses SwiftUI's, which is what this is drawn into.
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focused = nil }
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
            heading(model)
            switch model.step {
            case .needsLink, .community:
                communityStep(model)
            case .identity, .joining:
                identityStep(model)
            }
            if let error = model.error {
                Section {
                    Text(error)
                        .font(.hive(.footnote))
                        .foregroundStyle(.red)
                        .accessibilityLabel("Error: \(error)")
                }
            }
            actionSection(model)
        }
        .disabled(model.step == .joining)
        // The step is what the whole screen is about, so it is the one thing worth animating:
        // the sections swap rather than cutting. Scoped to `step` alone — animating on every
        // change would put a movement under each keystroke in the link field.
        .animation(.snappy, value: model.step)
    }

    /// What this step is asking, over the controls that ask it.
    ///
    /// Named rather than numbered — `Step 2 of 2` says where you are in a form, and
    /// `Who you'll be here` says what the screen is for. Two steps do not need a progress
    /// indicator to be legible; the heading changing *is* the progress.
    private func heading(_ model: JoinCommunityModel) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.stepTitle)
                    .font(.hive(.title3, weight: .semibold))
                Text(model.stepBlurb)
                    .font(.hive(.footnote))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 8, trailing: 4))
            .listRowBackground(Color.clear)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
        }
    }

    // MARK: - Step one: the community, and what it asks

    @ViewBuilder
    private func communityStep(_ model: JoinCommunityModel) -> some View {
        @Bindable var model = model
        if model.link != nil {
            cardSection(model.lookup)
        }
        linkSection(text: $model.linkText, note: model.linkNote, host: model.link?.host)
        if model.link != nil {
            if let community = model.alreadyJoined {
                alreadyJoinedSection(community)
            } else if model.isReadingPolicy {
                Section {
                    LabeledContent("This community's terms") {
                        ProgressView().controlSize(.small)
                    }
                }
            } else if let policy = model.policy, let link = model.link, link.policyReceipt == nil {
                policySection(
                    policy: policy,
                    link: link,
                    label: model.termsAgreementLabel,
                    ageConfirmed: $model.ageConfirmed,
                    termsAccepted: $model.termsAccepted
                )
            }
        }
    }

    /// The community itself, above everything the reader has to fill in — because *which
    /// community* is the decision, and the rest is only how.
    private func cardSection(_ lookup: CommunityLookup) -> some View {
        Section {
            CommunityCard(
                name: lookup.name,
                icon: lookup.icon,
                isChecking: lookup.isChecking,
                isVerified: lookup.isVerified
            )
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        }
    }

    private func linkSection(text: Binding<String>, note: String, host: String?) -> some View {
        Section {
            TextField("https://relay.example/invite/…", text: text, axis: .vertical)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .lineLimit(1 ... 3)
                .focused($focused, equals: .link)
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
            // under the field it is about. Once it *has* resolved, the host replaces the
            // advice — it is the one part of an invite a reader is expected to actually
            // check, and the card above it is named after a host rather than by one.
            if let host {
                Label(host, systemImage: "checkmark.seal")
                    .font(.hiveMono(.footnote))
                    .foregroundStyle(.green)
            } else {
                Text(note)
            }
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

    /// The operator's terms, the acceptance the relay will demand proof of, and — new — the
    /// reader's own agreement to the documents.
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
        label: String,
        ageConfirmed: Binding<Bool>,
        termsAccepted: Binding<Bool>
    ) -> some View {
        Section {
            if policy.termsMarkdown != nil {
                Button("Terms of Service") { open(document: "terms", of: link) }
            }
            if policy.privacyMarkdown != nil {
                Button("Privacy Policy") { open(document: "privacy", of: link) }
            }
            if policy.termsMarkdown != nil || policy.privacyMarkdown != nil {
                // The switch Hive did not have. It listed the documents and then took a press
                // on a button labelled `Join` as agreement to both; Desktop holds its own
                // button until this is on (`JoinPolicyNotice.tsx:60-105`), and a relay that
                // publishes terms is owed the same deliberate answer from either client.
                Toggle(label, isOn: termsAccepted)
            }
            if policy.ageAttestationRequired {
                Toggle("I meet this community's minimum age", isOn: ageConfirmed)
            }
        } header: {
            Text("THIS COMMUNITY'S TERMS")
        } footer: {
            Text(
                policy.ageAttestationRequired
                    ? "Joining records that you accepted these terms and made this statement. "
                    + "Required by this community, not by Hive."
                    : "Joining records that you accepted these terms. Required by this "
                    + "community, not by Hive."
            )
        }
    }

    // MARK: - Step two: who the reader will be here

    @ViewBuilder
    private func identityStep(_ model: JoinCommunityModel) -> some View {
        @Bindable var model = model
        nameSection(displayName: $model.displayName)
        identitySection(identity: $model.identity, nsec: $model.nsec)
    }

    /// The name this community will show for the reader. Optional, and never gates the join:
    /// a relay admits a key, not a name.
    private func nameSection(displayName: Binding<String>) -> some View {
        Section {
            TextField("Your name", text: displayName)
                .textContentType(.nickname)
                .focused($focused, equals: .name)
        } header: {
            Text("WHAT SHOULD PEOPLE CALL YOU?")
        } footer: {
            Text(JoinCommunityModel.displayNameBlurb)
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
                    .focused($focused, equals: .nsec)
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

    // MARK: - The button

    /// The one control that moves the screen on, in the app's own prominent style rather than
    /// as a row of the table above it — it is the thing this screen is for, and a plain row
    /// reading `Next` competes with the fields for rank.
    private func actionSection(_ model: JoinCommunityModel) -> some View {
        Section {
            Button {
                // The keyboard goes back before anything moves. A step that changed under a
                // raised keyboard would swap the sections behind it and leave the reader
                // looking at a field that is no longer there.
                focused = nil
                // Unstructured on purpose: a successful join closes this sheet, and a
                // `.task`-owned child would be cancelled by that teardown while the
                // engine it started was still coming up.
                Task { await model.primaryAction() }
            } label: {
                HStack(spacing: 6) {
                    if model.step == .joining {
                        ProgressView().controlSize(.small)
                    }
                    Text(model.actionTitle)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(!model.canContinue || model.step == .joining)
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            .listRowBackground(Color.clear)
        } footer: {
            // Says why the button above is grey, at the moment it is. Reported twice as "it
            // stays disabled" — a dead control with nothing explaining it is the one state a
            // reader cannot get out of.
            if let note = model.blockedNote {
                Text(note)
            }
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
