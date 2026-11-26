import AppKit

public protocol FindBarDelegate: AnyObject {
    func findBar(_ bar: FindBar, didChangeQuery query: String)
    func findBar(_ bar: FindBar, didAdvance direction: FindBar.Direction)
    func findBarDidClose(_ bar: FindBar)
    func findBar(_ bar: FindBar, didRequestReplace kind: FindBar.ReplaceKind, with replacement: String)
    /// Return `false` while a TUI is running (alt-screen, mouse reporting, bracketed paste):
    /// `sendReplacement` synthesises DEL bytes + UTF-8 that a TUI would interpret as key input.
    func findBarShouldAllowReplace(_ bar: FindBar) -> Bool
    func findBar(_ bar: FindBar, didChangeOptions options: FindBar.Options)
    /// Called after the bar resized itself; a taller bar can cover a match that was clear of the shorter one.
    func findBarDidChangeHeight(_ bar: FindBar)
}

extension FindBarDelegate {
    public func findBarShouldAllowReplace(_ bar: FindBar) -> Bool { true }
    public func findBar(_ bar: FindBar, didChangeOptions options: FindBar.Options) {}
    public func findBarDidChangeHeight(_ bar: FindBar) {}
}

public final class FindBar: NSView, NSTextFieldDelegate {
    public enum Direction { case forward, backward }

    public enum ReplaceKind { case current, all }

    public struct Options: Equatable {
        public var caseSensitive: Bool
        public var regex: Bool
        public init(caseSensitive: Bool = false, regex: Bool = false) {
            self.caseSensitive = caseSensitive
            self.regex = regex
        }
    }

    public private(set) var options = Options() {
        didSet {
            guard options != oldValue else { return }
            delegate?.findBar(self, didChangeOptions: options)
        }
    }

    @objc public func toggleCaseSensitive(_ sender: Any?) {
        options.caseSensitive.toggle()
        applyPlaceholders()
    }

    @objc public func toggleRegexMode(_ sender: Any?) {
        options.regex.toggle()
        applyPlaceholders()
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

    public private(set) var isReplaceVisible: Bool = false

    public var preferredHeight: CGFloat { isReplaceVisible ? 60 : 32 }

    // MARK: - Width priorities

    /// Squeeze order, lowest first. Priorities must be distinct (the solver breaks ties arbitrarily) and stay
    /// below `windowSizeStayPut` (500), above which the layout engine stretches the bar instead of its contents.
    private static let fieldPreferredPriority = NSLayoutConstraint.Priority(rawValue: 400)
    private static let matchLabelPriority = NSLayoutConstraint.Priority(rawValue: 440)
    private static let replaceButtonPriority = NSLayoutConstraint.Priority(rawValue: 450)
    private static let fieldSoftFloorPriority = NSLayoutConstraint.Priority(rawValue: 470)
    private static let replaceAllButtonPriority = NSLayoutConstraint.Priority(rawValue: 480)
    private static let fieldHardFloorPriority = NSLayoutConstraint.Priority(rawValue: 490)

    // MARK: - Dynamic layout constraints

    private var collapsedConstraints: [NSLayoutConstraint] = []
    private var expandedConstraints:  [NSLayoutConstraint] = []

    // MARK: - Init

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        caretButton.translatesAutoresizingMaskIntoConstraints = false
        caretButton.bezelStyle = .inline
        caretButton.isBordered = false
        caretButton.font = .systemFont(ofSize: 11)
        caretButton.target = self
        caretButton.action = #selector(toggleReplaceRow)
        // Labels go on the cell: AppKit exposes the NSButtonCell, not the NSButton view, to accessibility.
        caretButton.cell?.setAccessibilityLabel("Show replace")

        field.placeholderString = "Find"
        field.delegate = self
        field.focusRingType = .none
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.translatesAutoresizingMaskIntoConstraints = false

        matchLabel.translatesAutoresizingMaskIntoConstraints = false
        matchLabel.font = .systemFont(ofSize: 11)
        matchLabel.textColor = .secondaryLabelColor
        matchLabel.cell?.setAccessibilityLabel("Find results")
        matchLabel.lineBreakMode = .byTruncatingTail
        matchLabel.setContentCompressionResistancePriority(Self.matchLabelPriority, for: .horizontal)

        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.target = self
        closeButton.action = #selector(closeAction)
        closeButton.cell?.setAccessibilityLabel("Close find bar")

        replaceField.placeholderString = "Replace"
        replaceField.delegate = self
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

        replaceButton.setContentCompressionResistancePriority(Self.replaceButtonPriority, for: .horizontal)
        replaceAllButton.setContentCompressionResistancePriority(Self.replaceAllButtonPriority, for: .horizontal)

        addSubview(caretButton)
        addSubview(field)
        addSubview(matchLabel)
        addSubview(closeButton)
        addSubview(replaceField)
        addSubview(replaceButton)
        addSubview(replaceAllButton)

        // The field's default compression resistance (750) is lowered so a long query can't out-vote the
        // width priorities.
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let fieldPreferredWidth = field.widthAnchor.constraint(equalToConstant: 220)
        fieldPreferredWidth.priority = Self.fieldPreferredPriority
        let fieldSoftFloorWidth = field.widthAnchor.constraint(greaterThanOrEqualToConstant: 60)
        fieldSoftFloorWidth.priority = Self.fieldSoftFloorPriority
        let fieldHardFloorWidth = field.widthAnchor.constraint(greaterThanOrEqualToConstant: 32)
        fieldHardFloorWidth.priority = Self.fieldHardFloorPriority

        NSLayoutConstraint.activate([
            caretButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            caretButton.widthAnchor.constraint(equalToConstant: 16),
            field.leadingAnchor.constraint(equalTo: caretButton.trailingAnchor, constant: 4),
            fieldPreferredWidth,
            fieldSoftFloorWidth,
            fieldHardFloorWidth,
            matchLabel.leadingAnchor.constraint(equalTo: field.trailingAnchor, constant: 10),
            matchLabel.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -6),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            replaceField.leadingAnchor.constraint(equalTo: field.leadingAnchor),
            replaceField.widthAnchor.constraint(equalTo: field.widthAnchor),
            replaceButton.leadingAnchor.constraint(equalTo: replaceField.trailingAnchor, constant: 8),
            replaceAllButton.leadingAnchor.constraint(equalTo: replaceButton.trailingAnchor, constant: 8),
        ])

        collapsedConstraints = [
            caretButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            matchLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ]

        expandedConstraints = [
            caretButton.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            field.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            matchLabel.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            closeButton.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            replaceField.topAnchor.constraint(equalTo: topAnchor, constant: 36),
            replaceButton.topAnchor.constraint(equalTo: topAnchor, constant: 36),
            replaceAllButton.topAnchor.constraint(equalTo: topAnchor, constant: 36),
            // Expanded-only: hidden views still take part in layout, and a collapsed bar must not give
            // up field width to buttons it isn't showing.
            replaceAllButton.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
        ]

        NSLayoutConstraint.activate(collapsedConstraints)
        replaceField.isHidden     = true
        replaceButton.isHidden    = true
        replaceAllButton.isHidden = true
    }

    public required init?(coder: NSCoder) { fatalError() }

    // MARK: - Layout

    public override func layout() {
        super.layout()
        // Alignment-rect width: on macOS 14/15 a push button's frame carries ~7 pt of invisible bezel
        // shadow per side.
        let replaceWidth = replaceButton.alignmentRect(forFrame: replaceButton.frame).width
        let fits = replaceWidth + 0.5 >= replaceButton.intrinsicContentSize.width
        let shouldHide = !isReplaceVisible || !fits
        if replaceButton.isHidden != shouldHide { replaceButton.isHidden = shouldHide }
    }

    // MARK: - Theming

    private var scheme: FindBarColorScheme?

    private var separatorView: NSView?

    public func applyTheme(_ palette: ThemePalette) {
        let scheme = FindBarColorScheme(palette: palette)
        self.scheme = scheme
        layer?.backgroundColor = Self.nsColor(rgb: scheme.barBackground).cgColor
        let text = Self.nsColor(rgb: scheme.text)
        let fieldBg = Self.nsColor(rgb: scheme.fieldBackground)
        styleThemedField(field, background: fieldBg, text: text)
        styleThemedField(replaceField, background: fieldBg, text: text)
        matchLabel.textColor = text.withAlphaComponent(0.65)
        applyPlaceholders()
        styleGlyphButtonTitles()
        installOrRetintSeparator(Self.nsColor(rgb: scheme.separator))
    }

    private func styleThemedField(_ f: NSTextField,
                                  background: NSColor, text: NSColor) {
        f.isBezeled = false
        f.drawsBackground = true
        f.backgroundColor = background
        f.textColor = text
        f.wantsLayer = true
        f.layer?.cornerRadius = 4
        // The fill is the cell's rectangular draw, not the layer's; without clipping the radius never shows.
        f.layer?.masksToBounds = true
    }

    private func applyPlaceholders() {
        var modes: [String] = []
        if options.regex { modes.append("Regular expression") }
        if options.caseSensitive { modes.append("Case sensitive") }
        field.cell?.setAccessibilityHelp(modes.isEmpty ? nil : modes.joined(separator: ", "))
        guard let scheme else {
            field.placeholderString = placeholderString()
            return
        }
        let muted = Self.nsColor(rgb: scheme.text).withAlphaComponent(0.5)
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: muted,
            .font: field.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
        ]
        field.placeholderAttributedString =
            NSAttributedString(string: placeholderString(), attributes: attrs)
        replaceField.placeholderAttributedString =
            NSAttributedString(string: "Replace", attributes: attrs)
    }

    private func styleGlyphButtonTitles() {
        guard let scheme else { return }
        let tint = Self.nsColor(rgb: scheme.text)
        for button in [caretButton, closeButton] {
            let font = button.font ?? NSFont.systemFont(ofSize: 11)
            button.attributedTitle = NSAttributedString(
                string: button.title,
                attributes: [.foregroundColor: tint, .font: font]
            )
        }
    }

    private func installOrRetintSeparator(_ color: NSColor) {
        if let separatorView {
            separatorView.layer?.backgroundColor = color.cgColor
            return
        }
        let hairline = NSView()
        hairline.wantsLayer = true
        hairline.layer?.backgroundColor = color.cgColor
        hairline.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hairline)
        NSLayoutConstraint.activate([
            hairline.leadingAnchor.constraint(equalTo: leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: trailingAnchor),
            hairline.bottomAnchor.constraint(equalTo: bottomAnchor),
            hairline.heightAnchor.constraint(equalToConstant: 1),
        ])
        separatorView = hairline
    }

    /// sRGB: `calibratedRed:` would shift every channel through the generic-RGB 1.8 gamma.
    private static func nsColor(rgb: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255.0,
            green: CGFloat((rgb >> 8) & 0xFF) / 255.0,
            blue: CGFloat(rgb & 0xFF) / 255.0,
            alpha: 1
        )
    }

    // MARK: - Focus

    public func focus() { window?.makeFirstResponder(field) }

    /// `makeFirstResponder` alone is a no-op when the field editor already has focus.
    public func focusAndSelectQuery() {
        focus()
        field.currentEditor()?.selectAll(nil)
    }

    public func setQuery(_ query: String) {
        field.stringValue = query
        delegate?.findBar(self, didChangeQuery: query)
    }

    // MARK: - Match label

    /// Bumped on every label write; `showTransientMessage`'s deferred clear fires only if its token is
    /// still the latest.
    private var transientMessageToken: UInt64 = 0

    private static let noMatchesText = "No matches"

    public func setMatchCount(_ current: Int, of total: Int) {
        transientMessageToken &+= 1
        let text = total == 0 ? FindBar.noMatchesText : "\(current + 1) / \(total)"
        guard matchLabel.stringValue != text else { return }
        matchLabel.stringValue = text
        announce(text)
    }

    private func announce(_ text: String) {
        NSAccessibility.post(
            element: matchLabel as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: text,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ]
        )
    }

    public func clearMatchLabel(keepingNoMatches: Bool = false) {
        transientMessageToken &+= 1
        if keepingNoMatches && matchLabel.stringValue == FindBar.noMatchesText { return }
        guard !matchLabel.stringValue.isEmpty else { return }
        matchLabel.stringValue = ""
    }

    public func triggerReplaceCurrent() {
        requestReplace(.current)
    }

    /// The single TUI-gated replace emission: every replace entry point routes here so the gate can't be bypassed.
    private func requestReplace(_ kind: ReplaceKind) {
        guard let delegate else { return }
        guard delegate.findBarShouldAllowReplace(self) else {
            showTransientMessage(FindBar.tuiActiveMessage)
            return
        }
        delegate.findBar(self, didRequestReplace: kind, with: replaceField.stringValue)
    }

    public static let tuiActiveMessage = "Replace unavailable while TUI is active"

    public func showTransientMessage(_ message: String) {
        transientMessageToken &+= 1
        let myToken = transientMessageToken
        let changed = matchLabel.stringValue != message
        matchLabel.stringValue = message
        if changed { announce(message) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            if self.transientMessageToken == myToken {
                self.matchLabel.stringValue = ""
            }
        }
    }

    // MARK: - Replace row visibility

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
            caretButton.cell?.setAccessibilityLabel("Hide replace")
        } else {
            NSLayoutConstraint.deactivate(expandedConstraints)
            NSLayoutConstraint.activate(collapsedConstraints)
            replaceField.isHidden     = true
            replaceButton.isHidden    = true
            replaceAllButton.isHidden = true
            caretButton.title = "▸"
            caretButton.cell?.setAccessibilityLabel("Show replace")
        }
        // Assigning a plain `title` resets the button to the system title color; re-tint from the theme.
        styleGlyphButtonTitles()
        needsLayout = true
        let h = preferredHeight
        guard frame.height != h else { return }
        let newOriginY = frame.origin.y + frame.height - h
        frame = NSRect(x: frame.origin.x, y: newOriginY, width: frame.width, height: h)
        delegate?.findBarDidChangeHeight(self)
    }

    // MARK: - Actions

    @objc private func toggleReplaceRow() {
        setReplaceVisible(!isReplaceVisible)
    }

    @objc private func closeAction() {
        delegate?.findBarDidClose(self)
    }

    @objc private func replaceCurrent() {
        requestReplace(.current)
    }

    @objc private func replaceAll() {
        requestReplace(.all)
    }

    // MARK: - NSTextFieldDelegate

    private var searchDebounceTimer: Timer?

    public func controlTextDidChange(_ notification: Notification) {
        // The Replace field shares this delegate; typing a replacement must not re-run the search.
        if (notification.object as? NSTextField) === replaceField { return }
        searchDebounceTimer?.invalidate()
        let query = field.stringValue
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
            if control === replaceField {
                requestReplace(.current)
            } else {
                var backward = false
                if let event = NSApp.currentEvent, event.type == .keyDown {
                    backward = event.modifierFlags.contains(.shift)
                }
                delegate?.findBar(self, didAdvance: backward ? .backward : .forward)
            }
            return true
        default:
            return false
        }
    }

    // MARK: - Bar-level keyboard contract

    /// A focused button has no field editor, so Esc arrives via `keyDown(with:)` or the responder chain.
    public override func cancelOperation(_ sender: Any?) {
        delegate?.findBarDidClose(self)
    }

    private static let escapeKeyCode: UInt16 = 53
    private static let returnKeyCode: UInt16 = 36
    private static let keypadEnterKeyCode: UInt16 = 76

    /// Unhandled keys continue up to TerminalView, whose `keyDown` encodes them into the PTY: Return / Enter
    /// are swallowed so a stray CR can never reach the shell.
    public override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case FindBar.escapeKeyCode:
            cancelOperation(nil)
        case FindBar.returnKeyCode, FindBar.keypadEnterKeyCode:
            break
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: - Test hooks

    #if DEBUG
    public func _setReplaceFieldStringForTests(_ value: String) {
        replaceField.stringValue = value
    }

    public func _clickReplaceCurrentForTests() {
        replaceCurrent()
    }

    public func _clickReplaceAllForTests() {
        replaceAll()
    }

    public func _matchLabelStringForTests() -> String {
        matchLabel.stringValue
    }

    public func _appliedSchemeForTests() -> FindBarColorScheme? {
        scheme
    }

    public func _barLayerBackgroundForTests() -> CGColor? {
        layer?.backgroundColor
    }

    public func _matchLabelTextColorForTests() -> NSColor? {
        matchLabel.textColor
    }

    public func _findFieldColorsForTests() -> (background: NSColor?, text: NSColor?) {
        (field.backgroundColor, field.textColor)
    }
    #endif
}
