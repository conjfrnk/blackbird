import Foundation

#if DEBUG
/// Lives in the app target so `TerminalView`'s stored property type resolves under `@testable import`.
final class RecordingPTY {
    var sent = Data()
    init() {}
}
#endif
