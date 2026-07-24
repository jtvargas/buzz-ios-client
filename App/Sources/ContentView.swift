import BuzzKit
import NostrCore
import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.largeTitle)
            Text("buzz-ios-client")
                .font(.headline)
            Text("core \(NostrCore.version)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
