import SwiftUI
import UIKit

/// The half of the account that cannot be edited: the keypair this device signs with and
/// the NIP-05 handle issued against it.
///
/// Separated from the profile fields rather than listed alongside them, because "your
/// name" and "your key" invite completely different actions — one is changed, the other is
/// copied or backed up — and a single list of rows where some are editable and some are
/// not gives no way to tell which is which before tapping.
struct AccountIdentityCard: View {
    let model: ProfileModel
    /// The key to back up. `nil` before the session has one, which drops the row rather
    /// than offering a backup of nothing.
    let selfPubkey: String?

    @State private var copiedKey = false

    var body: some View {
        AccountCard(
            title: "Identity",
            subtitle: "Your keypair and NIP-05 handle are fixed for this device."
        ) {
            EmptyView()
        } content: {
            publicKeyRow
            Divider()
            AccountFieldRow(label: "NIP-05 handle") {
                AccountUnsetValue(value: model.nip05)
            }
            if let selfPubkey {
                Divider()
                secretKeyRow(selfPubkey)
            }
        }
    }

    // MARK: - Public key

    /// The key, with a copy action.
    ///
    /// Shown and copied as `npub1…` rather than as the hex Buzz's desktop profile screen
    /// prints. This app made that call once already — see ``ProfileSheetView/displayKey(for:)``
    /// and ADR-0004 §1 — on the grounds that the npub is the spelling every other client
    /// asks for. Two screens in one app showing the same person's key two different ways
    /// is worse than either choice, so this one follows the profile sheet.
    private var publicKeyRow: some View {
        Button {
            UIPasteboard.general.string = model.npub
            copiedKey = true
        } label: {
            AccountFieldRow(label: "Public key") {
                HStack(spacing: 10) {
                    Text(ProfileSheetView.middleTruncated(model.npub))
                        .font(.hiveMono(.footnote))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Image(systemName: copiedKey ? "checkmark" : "doc.on.doc")
                        .font(.hiveSymbol(.footnote, weight: .semibold))
                        .foregroundStyle(copiedKey ? AnyShapeStyle(.green) : AnyShapeStyle(.tint))
                        .contentTransition(.symbolEffect(.replace))
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(copiedKey ? "Public key copied" : "Copy your public key")
        .animation(.snappy(duration: 0.2), value: copiedKey)
        // An acknowledgement rather than a state — the same rule the profile sheet's key
        // row follows, and for the same VoiceOver reason: left set, the control reads as
        // "Public key copied" forever and a second reader's own tap says nothing.
        .task(id: copiedKey) {
            guard copiedKey else { return }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            copiedKey = false
        }
    }

    // MARK: - Secret key

    /// The way through to ``KeyBackupView``, which is where the reveal actually happens —
    /// behind a device-authentication prompt, with a pasteboard that expires. Desktop puts
    /// a Reveal button in this row; the guarded screen is the same offer with the checks
    /// this app already wrote for it.
    private func secretKeyRow(_ selfPubkey: String) -> some View {
        NavigationLink {
            KeyBackupView(selfPubkey: selfPubkey)
        } label: {
            AccountFieldRow(label: "Secret key") {
                HStack(spacing: 10) {
                    Text("Reveal and back up")
                        .font(.hive(.body))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Image(systemName: "eye")
                        .font(.hiveSymbol(.footnote, weight: .semibold))
                        .foregroundStyle(.tint)
                }
            }
        }
        .buttonStyle(.plain)
    }
}
