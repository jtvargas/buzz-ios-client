import SwiftUI

struct AgentActivityWorkingIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var body: some View {
        Group {
            if reduceMotion || isLuminanceReduced {
                Image(systemName: "ellipsis")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            } else {
                // Indeterminate work, never a percentage or an invented countdown.
                // WidgetKit controls rendering; no animation timer runs here.
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
            }
        }
        .frame(width: 20, height: 20)
    }
}
