import BuzzKit
import SwiftUI

/// Joining a community by invitation, in three steps, on the same honeycomb the welcome screen
/// opens on.
///
/// # Why three, when this was two, and one before that
///
/// It was one screen on the argument that the reader is making a single decision — *do I want to
/// be in this* — and that everything they need in order to make it belongs in front of them at
/// once. That stopped being true as the screen grew: it carries the community and its terms, a
/// name, a picture, and a choice of key, and only the first is the decision. The rest are
/// consequences of having already made it.
///
/// So: **the community and its terms**, then **who you'll be in it**, then **the key that signs
/// for you**. The last two were one step, and splitting them is what this revision is for — the
/// name was a field above a key picker, which is the least similar pair of questions on the
/// screen, and it was the one people skipped. Desktop draws the same three
/// (`InviteRedeemForm.tsx:317` ends the invite step; `CommunityOnboardingFlow.tsx` runs profile
/// and key after it). The split itself is § ``JoinCommunityModel/Step``; this file draws it.
///
/// # Why it is not a `Form` any more
///
/// A grouped table is the right shape for several unrelated settings on one screen. This is a
/// walk with three stops, and — since the hero was rebuilt — it runs over an animated lattice
/// that a `Form` covers with an opaque slab. The steps are laid out by hand now out of the glass
/// cards in ``JoinCommunityChrome``, which are the same ones ``CommunityCard`` and
/// ``OnboardingRelayField`` already use on the screen this flow is entered from. Nothing the
/// table was doing is lost: its section headers are ``JoinCardLabel``, its footers are
/// ``JoinCardNote``, and its rows are the controls themselves.
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
    /// § ``JoinField``.
    @FocusState private var focused: JoinField?

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    wizard(model)
                } else {
                    // At most one frame, before the task below runs.
                    Color.clear
                }
            }
            .background { HoneycombBackground() }
            .navigationBarTitleDisplayMode(.inline)
            // The step's own heading is the title, in the type size a title deserves. A second
            // one in the bar would name the same thing twice, and the bar's material would put
            // a grey band across the top of the lattice to do it.
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if let model, model.canGoBack {
                        // Back rather than Cancel, in the place a reader already looks for it.
                        // Cancelling from here is the sheet's own downward drag, which is
                        // unambiguous; a Back that also abandoned the join would not be.
                        Button("Back") {
                            focused = nil
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
                // shell, which does its own keyboard avoidance and would double-count.
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focused = nil }
                }
            }
        }
        // The flow owns its appearance, the same way ``OnboardingView`` does: an amber lattice
        // out of near-black is the look, and its light-mode counterpart is a grey mesh on white.
        .preferredColorScheme(.dark)
        // Without this the sheet keeps the system's own background, which shows as a pale seam
        // around a screen that is meant to be one dark pane.
        .presentationBackground(.hiveNight)
        .task {
            guard model == nil else { return }
            model = JoinCommunityModel(environment: environment, initialLink: initialLink)
        }
    }

    // MARK: - The walk

    private func wizard(_ model: JoinCommunityModel) -> some View {
        // A `VStack` rather than a `safeAreaInset`, so the button gets its height out of the
        // layout instead of overlaying the scroll: the last card on a step is then scrollable
        // clear of it rather than resting permanently underneath.
        VStack(spacing: 0) {
            steps(model)
            actionBar(model)
        }
    }

    private func steps(_ model: JoinCommunityModel) -> some View {
        @Bindable var model = model
        let progress = model.stepNumber
        return ScrollView {
            VStack(spacing: 14) {
                JoinStepHeader(
                    index: progress.index,
                    count: progress.count,
                    title: model.stepTitle,
                    blurb: model.stepBlurb
                )
                .padding(.bottom, 2)

                switch model.step {
                case .needsLink, .community:
                    communityStep(model)
                case .profile:
                    JoinCommunityProfileStep(
                        displayName: $model.displayName,
                        emoji: $model.avatarEmoji,
                        color: $model.avatarColor,
                        focused: $focused
                    )
                case .identity, .joining:
                    identityStep(model)
                }

                if let error = model.error {
                    JoinCard {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.hive(.footnote))
                            .foregroundStyle(.red)
                            .accessibilityLabel("Error: \(error)")
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, 20)
            // An onboarding screen stretched edge to edge on an iPad is one card with three
            // feet of nothing on either side of it.
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.interactively)
        .disabled(model.step == .joining)
        // The step is what the whole screen is about, so it is the one thing worth animating:
        // the cards swap rather than cutting. Scoped to `step` alone — animating on every
        // change would put a movement under each keystroke in the link field.
        .animation(.snappy, value: model.step)
    }

    // MARK: - Step one: the community, and what it asks

    @ViewBuilder
    private func communityStep(_ model: JoinCommunityModel) -> some View {
        @Bindable var model = model
        // The community itself, above everything the reader has to fill in — because *which
        // community* is the decision, and the rest is only how.
        if model.link != nil {
            CommunityCard(
                name: model.lookup.name,
                icon: model.lookup.icon,
                isChecking: model.lookup.isChecking,
                isVerified: model.lookup.isVerified
            )
        }
        linkCard(text: $model.linkText, note: model.linkNote, host: model.link?.host)
        if model.link != nil {
            if let community = model.alreadyJoined {
                JoinCard {
                    Label(
                        "You're already in \(community.name) on this phone.",
                        systemImage: "checkmark.circle"
                    )
                    .font(.hive(.subheadline))
                    .foregroundStyle(.white.opacity(0.85))
                }
            } else if model.isReadingPolicy {
                JoinCard {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Reading this community's terms…")
                            .font(.hive(.subheadline))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
            } else if let policy = model.policy, let link = model.link, link.policyReceipt == nil {
                policyCard(
                    policy: policy,
                    link: link,
                    label: model.termsAgreementLabel,
                    ageConfirmed: $model.ageConfirmed,
                    termsAccepted: $model.termsAccepted
                )
            }
        }
    }

    private func linkCard(text: Binding<String>, note: String, host: String?) -> some View {
        JoinCard {
            JoinCardLabel(text: "INVITE LINK", systemImage: "link")
            TextField("", text: text, prompt: linkPrompt, axis: .vertical)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .lineLimit(1 ... 3)
                .focused($focused, equals: .link)
                .joinFieldBackground()
            HStack {
                // `PasteButton` rather than a plain button reading `UIPasteboard`, because
                // that is the one shape of paste iOS does not interrupt with a permission
                // alert — and this field is pasted into far more often than it is typed in.
                // Glass rather than its default prominent fill, which is a solid amber pill
                // and the same objection as the welcome screen's old primary button.
                PasteButton(payloadType: String.self) { strings in
                    guard let pasted = strings.first else { return }
                    Task { @MainActor in text.wrappedValue = pasted }
                }
                .labelStyle(.titleAndIcon)
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                Spacer(minLength: 0)
            }
            // The note carries the diagnosis rather than the error card: text that has not
            // resolved into an invitation is not a failure, and the sentence belongs under the
            // field it is about. Once it *has* resolved, the host replaces the advice — it is
            // the one part of an invite a reader is expected to actually check, and the card
            // above it is named after a host rather than by one.
            if let host {
                Label(host, systemImage: "checkmark.seal")
                    .font(.hiveMono(.footnote))
                    .foregroundStyle(.green)
            } else {
                JoinCardNote(text: note)
            }
        }
    }

    /// Dimmed rather than left to the platform's placeholder grey, which on glass over a dark
    /// lattice is very nearly the same value as the field's own fill.
    ///
    /// `verbatim` is load-bearing: `Text` parses a string literal as Markdown, and Markdown
    /// autolinks a bare URL — so the plain initialiser drew this placeholder as a live blue
    /// link, which is both the wrong colour and a claim that the example address is tappable.
    private var linkPrompt: Text {
        Text(verbatim: "https://relay.example/invite/…").foregroundStyle(.white.opacity(0.3))
    }

    /// The operator's terms, the acceptance the relay will demand proof of, and the reader's
    /// own agreement to the documents.
    ///
    /// The documents open in the browser rather than being rendered here: the relay serves
    /// each as a real page (`/api/join-policy/terms`), Desktop hands them to the system
    /// browser for the same reason (`invites.ts:106-113`), and a legal document read inside
    /// a modal sheet with nowhere to go back to is worse than one read in Safari.
    ///
    /// Not shown at all when the link already carries a receipt: that acceptance was made
    /// in a browser, on the relay's own page, and asking for it twice would suggest the
    /// first one did not count.
    private func policyCard(
        policy: JoinPolicy,
        link: InviteLink,
        label: String,
        ageConfirmed: Binding<Bool>,
        termsAccepted: Binding<Bool>
    ) -> some View {
        JoinCard(spacing: 12) {
            JoinCardLabel(text: "THIS COMMUNITY'S TERMS", systemImage: "doc.text")
            if policy.termsMarkdown != nil {
                documentLink("Terms of Service", document: "terms", of: link)
            }
            if policy.privacyMarkdown != nil {
                documentLink("Privacy Policy", document: "privacy", of: link)
            }
            if policy.termsMarkdown != nil || policy.privacyMarkdown != nil {
                // The switch Hive did not have. It listed the documents and then took a press
                // on a button labelled `Join` as agreement to both; Desktop holds its own
                // button until this is on (`JoinPolicyNotice.tsx:60-105`), and a relay that
                // publishes terms is owed the same deliberate answer from either client.
                Toggle(label, isOn: termsAccepted)
                    .font(.hive(.subheadline))
                    .tint(.hiveAccent)
            }
            if policy.ageAttestationRequired {
                Toggle("I meet this community's minimum age", isOn: ageConfirmed)
                    .font(.hive(.subheadline))
                    .tint(.hiveAccent)
            }
            JoinCardNote(
                text: policy.ageAttestationRequired
                    ? "Joining records that you accepted these terms and made this statement. "
                    + "Required by this community, not by Hive."
                    : "Joining records that you accepted these terms. Required by this "
                    + "community, not by Hive."
            )
        }
    }

    private func documentLink(_ title: String, document: String, of link: InviteLink) -> some View {
        Button {
            open(document: document, of: link)
        } label: {
            HStack(spacing: 6) {
                Text(title)
                Image(systemName: "arrow.up.right")
                    .font(.hive(.caption2, weight: .semibold))
                Spacer(minLength: 0)
            }
            .font(.hive(.subheadline, weight: .medium))
            .foregroundStyle(.hiveAccent)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens in your browser")
    }

    // MARK: - Step three: the key

    @ViewBuilder
    private func identityStep(_ model: JoinCommunityModel) -> some View {
        recapCard(model)
        keyCard(model)
    }

    /// What is about to happen, in one row: the community, and who the reader will be in it.
    ///
    /// The last step is the one where the button says `Join` rather than `Next`, and it is two
    /// screens away from the community card and one from the name — so without this, the moment
    /// of committing is the moment with the least on screen about what is being committed to.
    /// It doubles as the confirmation that the previous step was answered, which is the only
    /// place a reader can find that out now that the name lives on a screen of its own.
    private func recapCard(_ model: JoinCommunityModel) -> some View {
        JoinCard {
            HStack(spacing: 12) {
                CommunityMark(name: model.lookup.name, icon: model.lookup.icon, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.lookup.name)
                        .font(.hive(.subheadline, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(joiningAs(model))
                        .font(.hive(.caption2))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if let emoji = model.avatarEmoji {
                    Circle()
                        .fill(Color(avatarHex: model.avatarColor) ?? .white)
                        .frame(width: 34, height: 34)
                        .overlay { Text(emoji).font(.hive(fixedSize: 17, relativeTo: .body)) }
                        .overlay(Circle().strokeBorder(.white.opacity(0.22), lineWidth: 1))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
    }

    private func joiningAs(_ model: JoinCommunityModel) -> String {
        let name = model.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Joining without a name" : "Joining as \(name)"
    }

    private func keyCard(_ model: JoinCommunityModel) -> some View {
        @Bindable var model = model
        return JoinCard(spacing: 12) {
            JoinCardLabel(text: "IDENTITY", systemImage: "key")
            Picker("Identity", selection: $model.identity) {
                ForEach(JoinCommunityModel.Identity.allCases) { choice in
                    Text(choice.label).tag(choice)
                }
            }
            .pickerStyle(.segmented)
            if model.identity == .existing {
                SecureField("", text: $model.nsec, prompt: nsecPrompt)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focused, equals: .nsec)
                    .joinFieldBackground()
            }
            JoinCardNote(
                text: model.identity == .new
                    ? JoinCommunityModel.newIdentityWarning
                    : JoinCommunityModel.existingIdentityBlurb
            )
        }
    }

    private var nsecPrompt: Text {
        Text("nsec1…").foregroundStyle(.white.opacity(0.3))
    }

    // MARK: - The button

    /// The one control that moves the screen on, pinned under the steps rather than scrolling
    /// with them — it is the thing this screen is for, and on a step whose content is optional
    /// a reader must never have to scroll to find the way forward.
    private func actionBar(_ model: JoinCommunityModel) -> some View {
        VStack(spacing: 8) {
            // Says why the button below is grey, at the moment it is. Reported twice as "it
            // stays disabled" — a dead control with nothing explaining it is the one state a
            // reader cannot get out of.
            if let note = model.blockedNote {
                JoinCardNote(text: note)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button {
                // The keyboard goes back before anything moves. A step that changed under a
                // raised keyboard would swap the cards behind it and leave the reader looking
                // at a field that is no longer there.
                focused = nil
                // Unstructured on purpose: a successful join closes this sheet, and a
                // `.task`-owned child would be cancelled by that teardown while the engine it
                // started was still coming up.
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
            // Glass, not `.glassProminent`: a flat accent slab over a lit amber lattice reads
            // as a sticker on the artwork rather than as a control sitting in it, which is the
            // same call the welcome screen's two routes now make.
            .buttonStyle(.glass)
            .controlSize(.large)
            .disabled(!model.canContinue || model.step == .joining)
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity)
        .animation(.snappy(duration: 0.25), value: model.blockedNote)
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
