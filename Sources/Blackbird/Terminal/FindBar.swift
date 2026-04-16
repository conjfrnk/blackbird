import AppKit

public protocol FindBarDelegate: AnyObject {
    func findBar(_ bar: FindBar, didChangeQuery query: String)
    func findBar(_ bar: FindBar, didAdvance direction: FindBar.Direction)
    func findBarDidClose(_ bar: FindBar)
}

public final class FindBar: NSView, NSTextFieldDelegate {
    public enum Direction { case forward, backward }

    public weak var delegate: FindBarDelegate?
    private let field = NSTextField()
    private let matchLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton(title: "✕", target: nil, action: nil)

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

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

        addSubview(field)
        addSubview(matchLabel)
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.widthAnchor.constraint(equalToConstant: 240),
            matchLabel.leadingAnchor.constraint(equalTo: field.trailingAnchor, constant: 10),
            matchLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    public required init?(coder: NSCoder) { fatalError() }

    public func focus() { window?.makeFirstResponder(field) }

    public func setMatchCount(_ current: Int, of total: Int) {
        matchLabel.stringValue = total == 0 ? "No matches" : "\(current + 1) / \(total)"
    }

    @objc private func closeAction() {
        delegate?.findBarDidClose(self)
    }

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
}
