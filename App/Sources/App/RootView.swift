import SwiftUI

/// The top of the view tree: the identity gate until a key is present, then the
/// channel list. Reads ``AppEnvironment`` from the environment so a phase change
/// (identity accepted, engine started) re-renders here automatically.
struct RootView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        switch environment.phase {
        case .needsIdentity:
            IdentityGateView()
        case .running:
            if let engine = environment.engine {
                ChannelListView(store: environment.store, engine: engine)
            } else {
                ProgressView()
            }
        case let .failed(message):
            ContentUnavailableView {
                Label("Hive couldn't start", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            }
        }
    }
}
