import SwiftUI

/// The six-digit SAS comparison — the human MITM check at the heart of NIP-AB. The
/// user must confirm the code shown here matches the one on the desktop *before*
/// the credential is imported; denying it aborts the pairing.
///
/// The prompt states plainly what is being authorised, and the code is rendered
/// large, monospaced, and digit-grouped so a mismatch is obvious at a glance.
struct SASComparisonView: View {
    let sasCode: String
    let onConfirm: () -> Void
    let onCancel: () -> Void

    private var groupedCode: String {
        guard sasCode.count == 6 else { return sasCode }
        let middle = sasCode.index(sasCode.startIndex, offsetBy: 3)
        return "\(sasCode[..<middle]) \(sasCode[middle...])"
    }

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 8) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 44))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text("Check your desktop")
                    .font(.title3.weight(.semibold))
                Text("You're about to move your identity to this device. Confirm your desktop shows the same code.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Text(groupedCode)
                .font(.system(size: 48, weight: .bold, design: .monospaced))
                .kerning(2)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity)
                .glassEffect(.regular, in: .rect(cornerRadius: 20))
                .accessibilityLabel("Pairing code \(sasCode.map(String.init).joined(separator: " "))")

            VStack(spacing: 12) {
                Button(action: onConfirm) {
                    Label("Codes Match", systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)

                Button(role: .cancel, action: onCancel) {
                    Text("Cancel")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
            }
            .controlSize(.large)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
