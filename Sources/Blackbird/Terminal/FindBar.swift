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
}

extension FindBarDelegate {
    /// Default: allow replace. Conformers that own terminal state should
    /// override this and inspect `BBTermMode` before returning `true`.
    public func findBarShouldAllowReplace(_ bar: FindBar) -> Bool { true }
}

public final class FindBar: NSView, NSTextFieldDelegate {
    public enum Direction { case forward, backward }

    /// Whether the replace operation targets just the current match or all matches.
    public enum ReplaceKind { case current, all }

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

    public func setMatchCount(_ current: Int, of total: Int) {
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
        matchLabel.stringValue = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            if self.matchLabel.stringValue == message {
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

    public func controlTextDidChange(_ notification: Notification) {
        delegate?.findBar(self, didChangeQuery: field.stringValue)
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
