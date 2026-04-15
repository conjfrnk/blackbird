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
        guard let term = BBTerm(size: .init(cols: 80, rows: 24)) else {
            return "BBTerm failed to init."
        }
        term.input("hello")
        guard let snap = term.snapshot() else {
            return "Snapshot failed."
        }
        return "First cell: \(snap.character(at: 0, row: 0).map(String.init) ?? "?")"
    }
}
