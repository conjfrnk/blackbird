import AppKit

/// Semi-transparent overlay shown inside the terminal window after the
/// shell exits. Displays "Process ended (exit N)" plus hint text. Key
/// handling (⏎ restart, ⌘W close) is done by the controller via
/// `onRestart` / `onClose` closures.
final class ShellExitOverlay: NSView {
    var onRestart: (() -> Void)?

    private let card = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let hintLabel  = NSTextField(labelWithString: "Press ⏎ to restart or ⌘W to close")

    init(exitCode: Int32) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor

        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        card.layer?.cornerRadius = 8
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 15, weight: .medium)
        titleLabel.textColor = .labelColor
        titleLabel.stringValue = "Process ended (exit \(exitCode))"

        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        hintLabel.font = .systemFont(ofSize: 12)
        hintLabel.textColor = .secondaryLabelColor

        card.addSubview(titleLabel)
        card.addSubview(hintLabel)

        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.centerYAnchor.constraint(equalTo: centerYAnchor),
            card.widthAnchor.constraint(greaterThanOrEqualToConstant: 320),

            titleLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: 20),
            titleLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),

            hintLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            hintLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            hintLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
            hintLabel.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -20),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        // Enter = restart. Everything else falls through (⌘W will hit
        // the window delegate via the responder chain).
        if event.keyCode == 36 || event.keyCode == 76 {   // Return / Enter
            onRestart?()
        } else {
            super.keyDown(with: event)
        }
    }
}
