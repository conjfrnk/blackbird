import SwiftUI

@main
struct BlackbirdApp: App {
    var body: some Scene {
        WindowGroup {
            Text("Blackbird — scaffolding online.")
                .font(.system(.title2, design: .monospaced))
                .padding()
                .frame(minWidth: 480, minHeight: 240)
        }
    }
}
