import BuzzKit
import NostrCore
import SwiftUI

/// Who someone is, on a Liquid Glass sheet: their picture, their name, whether they
/// are a person or an agent, whether they are here right now, their key when someone
/// genuinely needs it, and one action — message them.
///
/// # Why the sheet takes a pubkey and nothing else
///
/// Every field is resolved through the injected ``EntityNames`` and ``PresenceModel``,
/// the same two sources the timeline row and the sidebar read. So a name that lands
/// after the sheet opens updates it, and the sheet can never disagree with the row that
/// opened it — which is the whole reason identity resolution was centralised in Phase 5.
///
/// The key is one of the two places a full identifier is *deliberately* shown (ADR-0004
/// §1, amended): it is what someone came here to copy. It is labelled, monospaced, and
/// truncated in the middle, so it reads as a technical value rather than as a name — and
/// it is the `npub1…` form, because that is the spelling every other Nostr client takes.
///
/// # Why it scrolls
///
/// A `.medium` detent is about half the screen, and the sheet's content is measured in
/// Dynamic Type: one step up from the default pushes the key row — the thing the sheet
/// exists for — below the detent's edge. So the content scrolls and the sheet is allowed
/// to grow, rather than being a fixed box whose last element is unreachable at any text
/// size but one.
struct ProfileSheetView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.entityNames) private var names

    /// The identity this sheet is about.
    let pubkey: String
    /// Live presence, passed in rather than observed here so the sheet cannot become a
    /// second source of truth for who is online.
    let presence: PresenceModel
    /// Opens (or creates) the direct message with this person. `nil` while the
    /// capability is unavailable, which disables the action rather than faking it.
    var onMessage: ((String) -> Void)?

    @State private var didCopyKey = false

    private var isSelf: Bool {
        names.selfPubkey == pubkey.lowercased()
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    identity
                    if !isSelf, let onMessage {
                        messageButton(onMessage)
                    }
                    keyRow
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                // Bottom padding rather than a `Spacer`: inside a scroll view a spacer has
                // no height to take, so it neither pushes content up nor guarantees the
                // last row clears the sheet's edge.
                .padding(.bottom, 20)
            }
            // So the sheet does not rubber-band at the default text size, where the
            // content fits and there is nothing to scroll.
            .scrollBounceBehavior(.basedOnSize)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        // Both detents, medium first: the sheet still opens at half height, and a reader
        // whose text size (or whose peer's name) needs more room can take the whole screen
        // instead of scrolling a short window.
        .presentationDetents([.medium, .large])
    }

    // MARK: - Identity

    /// The header avatar's point size — the largest avatar the app draws anywhere, and so
    /// the number the relay-thumbnail rationale is measured against. Named rather than a
    /// literal for exactly that reason: `AvatarSourceTests` asserts that this times the
    /// largest display scale still fits inside ``RelayMediaURL/thumbnailMaximumPixelSize``,
    /// which a bump here would otherwise silently invert.
    static let avatarSize: CGFloat = 96

    private var identity: some View {
        VStack(spacing: 10) {
            AvatarView(
                url: names.picture(for: pubkey),
                seed: pubkey,
                monogram: names.initials(for: pubkey),
                size: Self.avatarSize
            )
            Text(names.name(for: pubkey))
                .font(.hive(.title2, weight: .semibold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
            HStack(spacing: 8) {
                Text(kindLabel)
                    .font(.hive(.subheadline))
                    .foregroundStyle(.secondary)
                Text(verbatim: "·")
                    .foregroundStyle(.tertiary)
                presenceLabel
            }
            if let secondary = names.secondaryLabel(for: pubkey), secondary != kindLabel {
                Text(secondary)
                    .font(.hive(.footnote))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(.top, 12)
        .accessibilityElement(children: .combine)
    }

    /// Person or agent — the distinction the directory already knows, so the sheet does
    /// not guess it from a name or a role string.
    private var kindLabel: String {
        names.isAgent(pubkey) ? "Agent" : "Member"
    }

    private var presenceLabel: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(PresenceDot.tint(isOnline: presence.isOnline(pubkey)))
                .frame(width: 8, height: 8)
            Text(presence.isOnline(pubkey) ? "Online" : "Offline")
                .font(.hive(.subheadline))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(presence.isOnline(pubkey) ? "Online" : "Offline")
    }

    // MARK: - Actions

    private func messageButton(_ action: @escaping (String) -> Void) -> some View {
        Button {
            // The sheet closes first, then the caller navigates: pushing a conversation
            // out from under a presented sheet leaves the sheet covering the thing it
            // just opened.
            dismiss()
            action(pubkey)
        } label: {
            Label("Message", systemImage: "bubble.left.and.text.bubble.right")
                .font(.hive(.body, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.glassProminent)
    }

    /// The key row's corner. Named because two things have to agree on it — the glass the
    /// row is drawn on, and the shape a press is washed in — and a wash in the wrong shape
    /// is more visible than no wash at all.
    private static let keyRowRadius: CGFloat = 12

    /// The key, with a copy action. Truncated in the middle so both ends — the part
    /// people actually compare — stay visible at any width.
    ///
    /// Shown and copied as `npub1…`, the bech32 form of NIP-19. The hex is what the
    /// protocol carries on the wire, but it is not what a person is asked for: another
    /// client's "add a contact" field, a profile link, and every published identity are the
    /// npub, so hex was the one spelling the string someone came here to copy could not be.
    /// The *whole* npub goes to the pasteboard; only the display is abbreviated.
    private var keyRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(names.isAgent(pubkey) ? "Agent key" : "Public key")
                .font(.hive(.caption, weight: .semibold))
                .foregroundStyle(.secondary)
            Button {
                UIPasteboard.general.string = displayKey
                didCopyKey = true
            } label: {
                HStack(spacing: 10) {
                    Text(Self.middleTruncated(displayKey))
                        .font(.hiveMono(.caption))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Image(systemName: didCopyKey ? "checkmark" : "doc.on.doc")
                        .font(.hiveSymbol(.caption, weight: .semibold))
                        .foregroundStyle(didCopyKey ? AnyShapeStyle(.green) : AnyShapeStyle(.tint))
                        .contentTransition(.symbolEffect(.replace))
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            // The row emphasis on something that does have edges, for a reason particular to
            // this control: the glass below is applied to the *button*, outside the style, so
            // it is not carried by the style's scale. A shrink would pull the key and its
            // glyph inward from a glass edge that stayed exactly where it was. The wash is
            // the whole of the feedback here, and it is drawn in the glass's own rectangle.
            .buttonStyle(.hivePress(.row, in: .rect(cornerRadius: Self.keyRowRadius)))
            .glassEffect(.regular, in: .rect(cornerRadius: Self.keyRowRadius))
            .accessibilityLabel(didCopyKey ? "Key copied" : "Copy key")
            .animation(.snappy(duration: 0.2), value: didCopyKey)
            // The checkmark is an acknowledgement, not a state: it says "that went to the
            // pasteboard just now". Left set it became permanent — including for VoiceOver,
            // which then read the control as "Key copied" for the rest of the sheet's life
            // and gave a second reader no way to know their own tap had done anything.
            .task(id: didCopyKey) {
                guard didCopyKey else { return }
                try? await Task.sleep(for: .seconds(2))
                // `try?` swallows the cancellation a dismissed sheet raises, so the flag is
                // asked about explicitly rather than reset on the way out.
                guard !Task.isCancelled else { return }
                didCopyKey = false
            }
        }
    }

    private var displayKey: String { Self.displayKey(for: pubkey) }

    /// The identifier this sheet shows and copies: the `npub1…` form.
    ///
    /// Falls back to the raw string when it is not a 32-byte hex key — a malformed or
    /// truncated pubkey has no bech32 form, and showing the bytes someone actually has is
    /// more useful than showing nothing. ``EntityNames/shortIdentifier(_:)`` makes the same
    /// call for the same reason. Static so the conversion is tested without a view host.
    static func displayKey(for pubkey: String) -> String {
        guard let raw = Hex.decode(pubkey.lowercased()), raw.count == 32 else { return pubkey }
        return NIP19.encodePublicKey(raw)
    }

    /// `key` with its middle elided, so both ends — the part people compare — stay visible
    /// at any width. Pure, so the boundary is tested rather than eyeballed.
    static func middleTruncated(_ key: String) -> String {
        guard key.count > 24 else { return key }
        return "\(key.prefix(12))…\(key.suffix(12))"
    }
}
