// impl: CTRL-001 rules 3, 8 · CTRL-003 — a HUD control.
//
// Custom-drawn rather than NSButton so the pressed feedback, the 40 % disabled
// opacity of rule 3, and the accessibility identifier are all in one place and
// cannot drift between controls.

import AppKit
import PlayA11y

@MainActor
final class HUDButton: NSView {
    private let imageView = NSImageView()
    private let a11y: A11yID
    private let action: () -> Void

    /// impl: CTRL-001 rule 3 — "applies but momentarily unavailable" renders at
    /// 40 % opacity. "Does not apply" means the control is absent, not disabled.
    var isEnabled = true {
        didSet { alphaValue = isEnabled ? 1 : 0.4 }
    }

    init(identifier: A11yID, symbol: String, accessibilityLabel: String,
         pointSize: CGFloat = 15, action: @escaping () -> Void) {
        self.a11y = identifier
        self.action = action
        super.init(frame: NSRect(x: 0, y: 0, width: 32, height: 32))
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.contentTintColor = .white
        addSubview(imageView)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 32),
            heightAnchor.constraint(equalToConstant: 32),
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        self.pointSize = pointSize
        setSymbol(symbol)

        setAccessibilityIdentifier(a11y.rawValue)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(accessibilityLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Play builds no nibs") }

    private var pointSize: CGFloat = 15

    /// impl: LIST-002 rule 11 — an on-state control is drawn in the accent
    /// colour. Called by HUDView for the shuffle button.
    func setTint(_ colour: NSColor) {
        imageView.contentTintColor = colour
    }

    /// Called whenever the glyph must follow state — PLAY-001's play/pause and
    /// PLAY-003's volume level are the two that change.
    func setSymbol(_ symbol: String) {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
        imageView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    }

    // MARK: - Interaction

    /// impl: CTRL-001 rule 8 — feedback on mouse-*down*, before the action.
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        PressFeedback.flash(self)
        log(.hudControlPressed, .info, ["element": a11y.rawValue])
    }

    override func mouseUp(with event: NSEvent) {
        guard isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        action()
    }

    /// The HUD is not a drag handle — WIN-001 rule 9.
    override var mouseDownCanMoveWindow: Bool { false }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        log(.hudControlPressed, .info, ["element": a11y.rawValue])
        action()
        return true
    }
}
