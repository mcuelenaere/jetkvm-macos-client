import SwiftUI

@main
struct JetKVMClientApp: App {
    var body: some Scene {
        WindowGroup("JetKVM") {
            ContentView()
                .frame(minWidth: 800, minHeight: 600)
        }
        .windowResizability(.contentSize)
    }
}

struct ContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("JetKVM Client")
                .font(.largeTitle)
            Text("Scaffolding ready. Implementation lands per milestone.")
                .foregroundStyle(.secondary)
        }
        .padding(40)
    }
}
