// impl: LIST-002 rules 5-7, 10 — one row of the queue panel.
//
// Custom-drawn like every other control in Play, so the state glyph, the middle
// truncation and the hover `✕` are all decided here rather than by a table
// cell's default behaviour.

import AppKit
import PlayA11y

@MainActor
final class QueueRowView: NSView {
    /// impl: LIST-002 rule 5 — ▸ playing, ✓ played, ⚠ failed, nothing pending.
    nonisolated static func glyph(for status: QueueItemStatus) -> String {
        switch status {
        case .playing: "▸"
        case .played: "✓"
        case .failed: "⚠"
        case .pending: " "
        }
    }

    private let index: Int
    private let status: QueueItemStatus
    private let glyphLabel = NSTextField(labelWithString: "")
    private let nameLabel = NSTextField(labelWithString: "")
    private let removeButton = NSButton()
    private var hovering = false
    private var mouseDownPoint: NSPoint?
    private var isDragging = false

    /// Set by QueueOverlayView; the row itself performs no queue mutation.
    var onClick: (() -> Void)?
    var onRemove: (() -> Void)?
    var onDragStart: ((NSEvent) -> Void)?
    var onDragUpdate: ((NSEvent) -> Void)?
    var onDragEnd: ((NSEvent) -> Void)?

    init(index: Int, item: QueueItem, isCurrent: Bool, isSelected: Bool) {
        self.index = index
        self.status = item.status
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        glyphLabel.stringValue = Self.glyph(for: item.status)
        glyphLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        // rule 5 — the failed glyph is amber, and only the glyph is coloured.
        glyphLabel.textColor = item.status == .failed ? .systemOrange : .white
        glyphLabel.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.stringValue = item.displayName
        nameLabel.font = .systemFont(ofSize: 12)
        nameLabel.textColor = .white
        // impl: LIST-002 rule 7 — middle truncation keeps the episode number,
        // which is the part that distinguishes files in a season.
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.cell?.truncatesLastVisibleLine = true
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // impl: LIST-002 rule 10 — the ✕ appears on hover; it is in the
        // hierarchy only while hovered, so a query for it is a real assertion
        // that the pointer is over the row (CTRL-003 rule 7).
        removeButton.title = "✕"
        removeButton.isBordered = false
        removeButton.font = .systemFont(ofSize: 11, weight: .bold)
        removeButton.contentTintColor = .white
        removeButton.target = self
        removeButton.action = #selector(removeClicked)
        removeButton.isHidden = true
        removeButton.translatesAutoresizingMaskIntoConstraints = false
        removeButton.setAccessibilityIdentifier(A11yID.queueRowRemove(index))
        removeButton.setAccessibilityLabel("Remove from queue")

        addSubview(glyphLabel)
        addSubview(nameLabel)
        addSubview(removeButton)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            glyphLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            glyphLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            glyphLabel.widthAnchor.constraint(equalToConstant: 14),
            nameLabel.leadingAnchor.constraint(equalTo: glyphLabel.trailingAnchor, constant: 6),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.trailingAnchor.constraint(equalTo: removeButton.leadingAnchor, constant: -6),
            removeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            removeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            removeButton.widthAnchor.constraint(equalToConstant: 18),
        ])

        // impl: LIST-002 rule 5 — failed rows are dimmed to 40 %.
        alphaValue = item.status == .failed ? 0.4 : 1
        // impl: LIST-002 rule 6 — the current row carries the accent colour; a
        // clicked-but-not-current row keeps a fainter selection fill so ⌫ has a
        // visible target (rule 10).
        if isCurrent {
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.35).cgColor
        } else if isSelected {
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
        }
        layer?.cornerRadius = 4

        setAccessibilityIdentifier(A11yID.queueRow(index))
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(item.displayName)
        setAccessibilityValue(item.status.rawValue)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Play builds no nibs") }

    // MARK: - Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        removeButton.isHidden = false
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        removeButton.isHidden = true
    }

    /// impl: LIST-002 rules 8-9 — a click plays the row; a drag reorders it.
    /// The two are told apart by 4 pt of vertical movement, so a slightly shaky
    /// click still plays rather than silently starting a drag.
    ///
    /// The drag is tracked through these overrides rather than through
    /// `NSDraggingSession`: source and destination are both inside the panel,
    /// so a pasteboard round-trip would buy nothing and would hand the event
    /// stream to AppKit's drag loop, where a UI test's synthetic mouse-up is
    /// easily lost.
    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        if isDragging {
            onDragUpdate?(event)
            return
        }
        guard let start = mouseDownPoint,
              abs(event.locationInWindow.y - start.y) > 4 else { return }
        isDragging = true
        onDragStart?(event)
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownPoint = nil; isDragging = false }
        if isDragging {
            onDragEnd?(event)
            return
        }
        guard mouseDownPoint != nil else { return }
        PressFeedback.flash(self)
        onClick?()
    }

    @objc private func removeClicked() {
        onRemove?()
    }
}
