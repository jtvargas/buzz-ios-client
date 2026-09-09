import SwiftUI

/// Persistent recovery belongs in the measured bar, where it reserves space for
/// itself and participates in the scaffold's existing scroll-position preservation.
struct ThreadLoadBanner: View {
    let message: String
    let isRetrying: Bool
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if isRetrying { ProgressView() }
            Text(isRetrying ? "Loading replies…" : message)
                .font(.hive(.caption, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Button("Retry", systemImage: "arrow.clockwise", action: retry)
                .labelStyle(.titleOnly)
                .disabled(isRetrying)
                .frame(minHeight: 44)
        }
        .padding(.horizontal, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
