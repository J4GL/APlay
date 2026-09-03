// impl: PLAY-003 rules 1, 3 — the volume slider.
//
// Custom-drawn rather than NSSlider because rule 1's amber fill above 100 % has
// no NSSlider expression, and the headroom is the whole reason the range goes
// past 100 in the first place.

import AppKit
import PlayA11y

@MainActor
final class VolumeSlider: NSView {
    private static let trackHeight: CGFloat = 3
    private static let width: CGFloat = 72

    private let volume: VolumeController
    private var isDragging = false

    init(volume: VolumeController) {
        self.volume = volume
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width),
            heightAnchor.constraint(equalToConstant: 20),
        ])
        setAccessibilityIdentifier(A11yID.hudVolumeSlider.rawValue)
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        setAccessibilityLabel("Volume")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Play builds no nibs") }

    private var trackRect: NSRect {
        NSRect(x: 0, y: (bounds.height - Self.trackHeight) / 2,
               width: bounds.width, height: Self.trackHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        let track = trackRect
        let radius = track.height / 2
        NSColor(white: 1, alpha: 0.3).setFill()
        NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()

        let fraction = CGFloat(volume.percent) / CGFloat(VolumeController.maxPercent)
        var filled = track
        filled.size.width = track.width * min(max(0, fraction), 1)
        // impl: PLAY-003 rule 1 — amber above 100 % signals possible clipping.
        (volume.percent > 100 ? NSColor.systemOrange : NSColor.white).setFill()
        NSBezierPath(roundedRect: filled, xRadius: radius, yRadius: radius).fill()
    }

    func refresh() { needsDisplay = true }

    // MARK: - Interaction

    private func percent(atX x: CGFloat) -> Int {
        guard bounds.width > 0 else { return volume.percent }
        let fraction = min(max(0, x / bounds.width), 1)
        return Int((fraction * CGFloat(VolumeController.maxPercent)).rounded())
    }

    /// impl: PLAY-003 rule 3 — drag or click to set.
    override func mouseDown(with event: NSEvent) {
        isDragging = true
        PressFeedback.flash(self)
        apply(event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        apply(event)
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
    }

    private func apply(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        volume.setVolume(percent: percent(atX: point.x), source: "slider",
                         element: A11yID.hudVolumeSlider.rawValue)
        needsDisplay = true
    }

    override var mouseDownCanMoveWindow: Bool { false }
}
