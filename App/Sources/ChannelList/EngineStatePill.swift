import BuzzKit
import SwiftUI

/// The engine-state pill for the channel-list toolbar: connecting / live /
/// suspended, driven by ``SyncEngine/states()`` (surfaced via ``AppEnvironment``).
struct EngineStatePill: View {
    let state: SyncEngine.State

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.hive(.caption, weight: .medium))
        }
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Connection: \(label)")
        .animation(.default, value: state)
    }

    private var label: String {
        switch state {
        case .stopped: "Offline"
        case .starting: "Connecting"
        case .running: "Live"
        case .suspended: "Paused"
        }
    }

    private var color: Color {
        switch state {
        case .stopped: .secondary
        case .starting: .orange
        case .running: .green
        case .suspended: .yellow
        }
    }
}
