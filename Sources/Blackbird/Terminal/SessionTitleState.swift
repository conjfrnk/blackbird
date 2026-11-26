import Foundation
import Combine

/// Not `@MainActor`: `publishTitle` hops to main before touching the `@Published`.
public final class SessionTitleState: ObservableObject {

    @Published public private(set) var title: String?

    /// Written on the main thread only.
    private var oscTitle: String = ""

    public var titleOverride: String? {
        didSet {
            if titleOverride?.isEmpty == true {
                if titleOverride != nil {
                    titleOverride = nil
                    return
                }
            }
            publishTitle()
        }
    }

    /// nil, not a placeholder, when neither source is set: the view's sink then shows its `defaultTitle`.
    public var displayTitle: String? {
        if let override = titleOverride, !override.isEmpty { return override }
        return oscTitle.isEmpty ? nil : oscTitle
    }

    public static let oscTitleMaxGraphemes = 256

    public func applyOscTitle(_ newValue: String) {
        oscTitle = Self.cappedOscTitle(newValue)
        publishTitle()
    }

    static func cappedOscTitle(_ value: String) -> String {
        if value.count <= oscTitleMaxGraphemes { return value }
        let prefix = value.prefix(oscTitleMaxGraphemes)
        return String(prefix) + "…"
    }

    /// Off main, read `displayTitle` inside the main-async block: its inputs are written on
    /// main, and a snapshot captured before the hop can deliver an older value last.
    private func publishTitle() {
        if Thread.isMainThread {
            self.title = displayTitle
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.title = self.displayTitle
            }
        }
    }
}
