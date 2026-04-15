import SwiftUI
import BBCore

@main
struct BlackbirdApp: App {
    var body: some Scene {
        WindowGroup {
            Text(Self.status)
                .font(.system(.title2, design: .monospaced))
                .padding()
                .frame(minWidth: 480, minHeight: 240)
        }
    }

    static var status: String {
        // Prove BBCore module types and functions are visible.
        let term = bb_term_new(80, 24, 10_000)
        defer { bb_term_free(term) }
        return term != nil ? "BBCore linked." : "BBCore failed to init."
    }
}
