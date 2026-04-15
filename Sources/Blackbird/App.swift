import SwiftUI

@main
struct BlackbirdApp: App {
    init() {
        let ok = FFILinkProbe.probe()
        precondition(ok, "BBCore did not link correctly.")
    }

    var body: some Scene {
        WindowGroup {
            Text("Blackbird — BBCore linked.")
                .font(.system(.title2, design: .monospaced))
                .padding()
                .frame(minWidth: 480, minHeight: 240)
        }
    }
}
