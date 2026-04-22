import AppKit

public protocol FindBarDelegate: AnyObject {
    func findBar(_ bar: FindBar, didChangeQuery query: String)
    func findBar(_ bar: FindBar, didAdvance direction: FindBar.Direction)
    func findBarDidClose(_ bar: FindBar)
    /// Fired when the user clicks "Replace" (`.current`) or "Replace All" (`.all`).
    func findBar(_ bar: FindBar, didRequestReplace kind: FindBar.ReplaceKind, with replacement: String)
    /// Asked before the replace delegate fires. Return `false` to refuse the
    /// replace operation — FindBar will display a transient warning instead of
    /// emitting bytes. Implementations should return `false` when the terminal
    /// is in a mode that indicates a TUI is running (alt-screen, mouse
    /// reporting, bracketed paste) because `sendReplacement` synthesises DEL
    /// bytes + UTF-8 that a TUI would interpret as key input.
    func findBarShouldAllowReplace(_ bar: FindBar) -> Bool
    /// Called when the user toggles the case-sensitivity or regex-mode
    /// state. Implementations should re-run the current search against
    /// the new options. Default: no-op (options are ignored).
    func findBar(_ bar: FindBar, didChangeOptions options: FindBar.Options)
}

extension FindBarDelegate {
    /// Default: allow replace. Conformers that own terminal state should
    /// override this and inspect `BBTermMode` before returning `true`.
    public func findBarShouldAllowReplace(_ bar: FindBar) -> Bool { true }
    /// Default: no-op. TerminalView's conformer overrides to re-run
    /// performSearch with the new flags.
    public func findBar(_ bar: FindBar, didChangeOptions options: FindBar.Options) {}
}

public final class FindBar: NSView, NSTextFieldDelegate {
    public enum Direction { case forward, backward }

    /// Whether the replace operation targets just the current match or all matches.
    public enum ReplaceKind { case current, all }

    /// Search options exposed through the find bar. Case-insensitive
    /// substring is still the default (matches Terminal.app / Safari
    /// / VS Code "off" state) — users opt into case-sensitive and/or
    /// regex mode via ⌘⌥C and ⌘⌥R respectively. Audit findbar-selection F1.
    public struct Options: Equatable {
        public var caseSensitive: Bool
        public var regex: Bool
        public init(caseSensitive: Bool = false, regex: Bool = false) {
            self.caseSensitive = caseSensitive
            self.regex = regex
        }
    }

    /// Current option state. Read by the delegate when re-running
    /// searches. Mutating either field fires the options-changed
    /// delegate hook so the search re-runs immediately.
    public private(set) var options = Options() {
        didSet {
            guard options != oldValue else { return }
            delegate?.findBar(self, didChangeOptions: options)
        }
    }

    @objc public func toggleCaseSensitive(_ sender: Any?) {
        options.caseSensitive.toggle()
        field.placeholderString = placeholderString()
    }

    @objc public func toggleRegexMode(_ sender: Any?) {
        options.regex.toggle()
        field.placeholderString = placeholderString()
    }

    private func placeholderString() -> String {
        var flags: [String] = []
        if options.regex { flags.append("regex") }
        if options.caseSensitive { flags.append("Aa") }
        return flags.isEmpty ? "Find" : "Find  [\(flags.joined(separator: " · "))]"
    }

    public weak var delegate: FindBarDelegate?

    // MARK: - Find row controls

    private let caretButton = NSButton(title: "▸", target: nil, action: nil)
    private let field       = NSTextField()
    private let matchLabel  = NSTextField(labelWithString: "")
    private let closeButton = NSButton(title: "✕", target: nil, action: nil)

    // MARK: - Replace row controls

    private let replaceField     = NSTextField()
    private let replaceButton    = NSButton(title: "Replace",     target: nil, action: nil)
    private let replaceAllButton = NSButton(title: "Replace All", target: nil, action: nil)

    // MARK: - Replace row visibility

    /// True when the replace row is shown. Defaults to `false`.
    public private(set) var isReplaceVisible: Bool = false

    /// Bar height callers should use when laying out the find bar.
    /// 32 pt when collapsed, 60 pt when the replace row is expanded.
    public var preferredHeight: CGFloat { isReplaceVisible ? 60 : 32 }

    // MARK: - Dynamic layout constraints

    /// Active only while the replace row is **hidden** (collapsed state).
    private var collapsedConstraints: [NSLayoutConstraint] = []
    /// Active only while the replace row is **visible** (expanded state).
    private var expandedConstraints:  [NSLayoutConstraint] = []

    // MARK: - Init

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        // ── Find row ───────────────────────────────────────────────────────
        caretButton.translatesAutoresizingMaskIntoConstraints = false
        caretButton.bezelStyle = .inline
        caretButton.isBordered = false
        caretButton.font = .systemFont(ofSize: 11)
        caretButton.target = self
        caretButton.action = #selector(toggleReplaceRow)

        field.placeholderString = "Find"
        field.delegate = self
        field.focusRingType = .none
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.translatesAutoresizingMaskIntoConstraints = false

        matchLabel.translatesAutoresizingMaskIntoConstraints = false
        matchLabel.font = .systemFont(ofSize: 11)
        matchLabel.textColor = .secondaryLabelColor

        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.target = self
        closeButton.action = #selector(closeAction)

        // ── Replace row ────────────────────────────────────────────────────
        replaceField.placeholderString = "Replace"
        replaceField.focusRingType = .none
        replaceField.isBezeled = true
        replaceField.bezelStyle = .roundedBezel
        replaceField.translatesAutoresizingMaskIntoConstraints = false

        replaceButton.bezelStyle = .push
        replaceButton.translatesAutoresizingMaskIntoConstraints = false
        replaceButton.target = self
        replaceButton.action = #selector(replaceCurrent)

        replaceAllButton.bezelStyle = .push
        replaceAllButton.translatesAutoresizingMaskIntoConstraints = false
        replaceAllButton.target = self
        replaceAllButton.action = #selector(replaceAll)

        addSubview(caretButton)
        addSubview(field)
        addSubview(matchLabel)
        addSubview(closeButton)
        addSubview(replaceField)
        addSubview(replaceButton)
        addSubview(replaceAllButton)

        // ── Permanent constraints (always active) ──────────────────────────
        NSLayoutConstraint.activate([
            // caret
            caretButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            caretButton.widthAnchor.constraint(equalToConstant: 16),
            // find field
            field.leadingAnchor.constraint(equalTo: caretButton.trailingAnchor, constant: 4),
            field.widthAnchor.constraint(equalToConstant: 220),
            // match label
            matchLabel.leadingAnchor.constraint(equalTo: field.trailingAnchor, constant: 10),
            // close button
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            // replace field (same x as find field, same width)
            replaceField.leadingAnchor.constraint(equalTo: field.leadingAnchor),
            replaceField.widthAnchor.constraint(equalTo: field.widthAnchor),
            // replace buttons
            replaceButton.leadingAnchor.constraint(equalTo: replaceField.trailingAnchor, constant: 8),
            replaceAllButton.leadingAnchor.constraint(equalTo: replaceButton.trailingAnchor, constant: 8),
        ])

        // ── Collapsed constraints (bar is 32 pt tall) ──────────────────────
        // Every control centres vertically within the whole 32 pt bar.
        collapsedConstraints = [
            caretButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            matchLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ]

        // ── Expanded constraints (bar is 60 pt tall) ───────────────────────
        // Find row centred in the top 32 pt slice; replace row centred in the
        // bottom 28 pt slice.  Use topAnchor + constant to pin each control.
        //
        // Top slice centre (from view top): 32/2 = 16 pt
        // Bottom slice centre (from view top): 32 + 28/2 = 46 pt
        // Controls are ~20 pt tall, so offset by half that → -10 pt.
        expandedConstraints = [
            // find row (centred at 16 pt from top → top edge at 6 pt)
            caretButton.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            field.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            matchLabel.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            closeButton.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            // replace row (centred at 46 pt from top → top edge at 36 pt)
            replaceField.topAnchor.constraint(equalTo: topAnchor, constant: 36),
            replaceButton.topAnchor.constraint(equalTo: topAnchor, constant: 36),
            replaceAllButton.topAnchor.constraint(equalTo: topAnchor, constant: 36),
        ]

        // Start in collapsed state.
        NSLayoutConstraint.activate(collapsedConstraints)
        replaceField.isHidden     = true
        replaceButton.isHidden    = true
        replaceAllButton.isHidden = true
    }

    public required init?(coder: NSCoder) { fatalError() }

    // MARK: - Focus

    public func focus() { window?.makeFirstResponder(field) }

    // MARK: - Match label

    /// Monotonic token bumped every time the match label is written. The
    /// deferred clear scheduled by `showTransientMessage` captures its
    /// token at schedule time and only wipes the label when the latest
    /// token still matches — so an A → B → A sequence where the second
    /// A arrives before the first A's 2 s deadline doesn't get
    /// prematurely wiped, and a `setMatchCount` between the schedule
    /// and fire invalidates the clear so the match count survives.
    /// Audit findbar-selection F6.
    private var transientMessageToken: UInt64 = 0

    public func setMatchCount(_ current: Int, of total: Int) {
        // Bump the token so any pending `showTransientMessage` clear
        // doesn't wipe this newly-written match count on its 2 s timer.
        // Audit findbar-selection F6.
        transientMessageToken &+= 1
        matchLabel.stringValue = total == 0 ? "No matches" : "\(current + 1) / \(total)"
    }

    /// Fires the replace-current delegate callback with the current replacement
    /// string. Equivalent to clicking the "Replace" button. Used by ⌘⌥E when
    /// the bar is already expanded. Honours the TUI-guard: if the delegate
    /// reports that replace is unsafe (alt-screen, mouse-reporting, or
    /// bracketed-paste active) the call is refused with a transient banner.
    public func triggerReplaceCurrent() {
        guard let delegate else { return }
        guard delegate.findBarShouldAllowReplace(self) else {
            showTransientMessage(FindBar.tuiActiveMessage)
            return
        }
        delegate.findBar(self, didRequestReplace: .current, with: replaceField.stringValue)
    }

    /// Banner shown when replace is refused because the terminal appears to be
    /// running a full-screen TUI. Exposed as a static constant so tests can
    /// assert against the exact wording.
    public static let tuiActiveMessage = "Replace unavailable while TUI is active"

    /// Shows a transient status message in the match label, auto-clearing after
    /// 2 seconds. Used by the replace path to surface
    /// "Only input-line matches can be replaced" without a modal alert.
    public func showTransientMessage(_ message: String) {
        transientMessageToken &+= 1
        let myToken = transientMessageToken
        matchLabel.stringValue = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            // Only clear when this scheduling is the most recent one. If
            // another `showTransientMessage` (or any other label write)
            // landed after us, the token advanced past ours and this work
            // item is stale. Audit findbar-selection F6.
            if self.transientMessageToken == myToken {
                self.matchLabel.stringValue = ""
            }
        }
    }

    // MARK: - Replace row visibility

    /// Show or hide the replace row. Callers are responsible for resizing the
    /// bar's frame to `preferredHeight` after calling this if needed.
    public func setReplaceVisible(_ visible: Bool) {
        guard visible != isReplaceVisible else { return }
        isReplaceVisible = visible

        if visible {
            NSLayoutConstraint.deactivate(collapsedConstraints)
            NSLayoutConstraint.activate(expandedConstraints)
            replaceField.isHidden     = false
            replaceButton.isHidden    = false
            replaceAllButton.isHidden = false
            caretButton.title = "▾"
        } else {
            NSLayoutConstraint.deactivate(expandedConstraints)
            NSLayoutConstraint.activate(collapsedConstraints)
            replaceField.isHidden     = true
            replaceButton.isHidden    = true
            replaceAllButton.isHidden = true
            caretButton.title = "▸"
        }
        needsLayout = true
    }

    // MARK: - Actions

    @objc private func toggleReplaceRow() {
        let nowVisible = !isReplaceVisible
        setReplaceVisible(nowVisible)
        // Resize the bar's own frame so the new height takes effect visually.
        let h = preferredHeight
        let newOriginY = frame.origin.y + frame.height - h
        frame = NSRect(x: frame.origin.x, y: newOriginY, width: frame.width, height: h)
    }

    @objc private func closeAction() {
        delegate?.findBarDidClose(self)
    }

    @objc private func replaceCurrent() {
        guard let delegate else { return }
        guard delegate.findBarShouldAllowReplace(self) else {
            showTransientMessage(FindBar.tuiActiveMessage)
            return
        }
        delegate.findBar(self, didRequestReplace: .current, with: replaceField.stringValue)
    }

    @objc private func replaceAll() {
        guard let delegate else { return }
        guard delegate.findBarShouldAllowReplace(self) else {
            showTransientMessage(FindBar.tuiActiveMessage)
            return
        }
        delegate.findBar(self, didRequestReplace: .all, with: replaceField.stringValue)
    }

    // MARK: - NSTextFieldDelegate

    /// Search debounce timer. Without this, every keystroke runs a full-
    /// scrollback scan (up to 10k matches × one FFI call per history row)
    /// while the user is still typing — wasted work the user can't see
    /// because the next keystroke invalidates the result. Coalesce typing
    /// bursts to one scan 150 ms after the last keystroke. Audit
    /// findbar-selection F38.
    private var searchDebounceTimer: Timer?

    public func controlTextDidChange(_ notification: Notification) {
        searchDebounceTimer?.invalidate()
        let query = field.stringValue
        // Empty query → fire immediately so the cleared-match state surfaces
        // in the UI without a 150 ms flicker of stale matches.
        if query.isEmpty {
            delegate?.findBar(self, didChangeQuery: query)
            return
        }
        searchDebounceTimer = Timer.scheduledTimer(
            withTimeInterval: 0.15,
            repeats: false
        ) { [weak self] _ in
            guard let self else { return }
            self.delegate?.findBar(self, didChangeQuery: self.field.stringValue)
        }
    }

    public func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.cancelOperation(_:)):
            delegate?.findBarDidClose(self)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            delegate?.findBar(self, didAdvance: .forward)
            return true
        case #selector(NSResponder.insertBacktab(_:)):
            delegate?.findBar(self, didAdvance: .backward)
            return true
        default:
            return false
        }
    }

    // MARK: - Test hooks

    #if DEBUG
    /// Sets the replace field's string value directly (for test injection).
    public func _setReplaceFieldStringForTests(_ value: String) {
        replaceField.stringValue = value
    }

    /// Simulates a click on the "Replace" button (replace current match).
    public func _clickReplaceCurrentForTests() {
        replaceCurrent()
    }

    /// Simulates a click on the "Replace All" button.
    public func _clickReplaceAllForTests() {
        replaceAll()
    }

    /// Reads the current match-label text so tests can assert that the
    /// TUI-guard transient banner fired.
    public func _matchLabelStringForTests() -> String {
        matchLabel.stringValue
    }
    #endif
}
