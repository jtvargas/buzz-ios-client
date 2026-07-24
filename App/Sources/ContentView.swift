import BuzzKit
import NostrCore
import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "hexagon.fill")
                .font(.largeTitle)
            Text("Hive")
                .font(.headline)
            Text("buzz client · core \(NostrCore.version)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .glassEffect(in: .rect(cornerRadius: 20))
    }
}

#Preview {
    ContentView()
}
