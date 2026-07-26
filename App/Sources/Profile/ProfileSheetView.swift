import BuzzKit
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
/// The key is the one place a raw 64-character identifier is *deliberately* shown: it is
/// what someone came here to copy. It is labelled, monospaced, and truncated in the
/// middle, so it reads as a technical value rather than as a name.
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
            VStack(spacing: 20) {
                identity
                if !isSelf, let onMessage {
                    messageButton(onMessage)
                }
                keyRow
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - Identity

    private var identity: some View {
        VStack(spacing: 10) {
            AvatarView(
                url: names.picture(for: pubkey),
                seed: pubkey,
                monogram: names.initials(for: pubkey),
                size: 96
            )
            Text(names.name(for: pubkey))
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
            HStack(spacing: 8) {
                Text(kindLabel)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(verbatim: "·")
                    .foregroundStyle(.tertiary)
                presenceLabel
            }
            if let secondary = names.secondaryLabel(for: pubkey), secondary != kindLabel {
                Text(secondary)
                    .font(.footnote)
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
                .fill(presence.isOnline(pubkey) ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 8, height: 8)
            Text(presence.isOnline(pubkey) ? "Online" : "Offline")
                .font(.subheadline)
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
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.glassProminent)
    }

    /// The key, with a copy action. Truncated in the middle so both ends — the part
    /// people actually compare — stay visible at any width.
    private var keyRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(names.isAgent(pubkey) ? "Agent key" : "Public key")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Button {
                UIPasteboard.general.string = pubkey
                didCopyKey = true
            } label: {
                HStack(spacing: 10) {
                    Text(middleTruncatedKey)
                        .font(.caption.monospaced())
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Image(systemName: didCopyKey ? "checkmark" : "doc.on.doc")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(didCopyKey ? AnyShapeStyle(.green) : AnyShapeStyle(.tint))
                        .contentTransition(.symbolEffect(.replace))
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular, in: .rect(cornerRadius: 12))
            .accessibilityLabel(didCopyKey ? "Key copied" : "Copy key")
            .animation(.snappy(duration: 0.2), value: didCopyKey)
        }
    }

    private var middleTruncatedKey: String {
        guard pubkey.count > 24 else { return pubkey }
        return "\(pubkey.prefix(12))…\(pubkey.suffix(12))"
    }
}
