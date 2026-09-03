// impl: PLAY-002 rules 1-8 — the seek bar.
//
// Click, drag and hover all resolve to a position through one function,
// `positionMs(atX:)`, so the three gestures cannot disagree about where the
// pointer is pointing.

import AppKit
import PlayA11y

@MainActor
final class SeekBar: NSView {
    private static let inset: CGFloat = 16
    private static let restHeight: CGFloat = 3
    private static let activeHeight: CGFloat = 6
    private static let knobDiameter: CGFloat = 12

    private let seeker: SeekController
    private let state: PlaybackState
    private let preview = NSTextField(labelWithString: "")

    private var isHovered = false
    private var isDragging = false
    private var trackingArea: NSTrackingArea?

    /// impl: CTRL-001 rule 5 — a drag suppresses auto-hide; set by HUDView.
    var onDragStateChange: ((Bool) -> Void)?

    init(seeker: SeekController, state: PlaybackState) {
        self.seeker = seeker
        self.state = state
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier(A11yID.hudSeekBar.rawValue)
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        setAccessibilityLabel("Seek bar")
        installPreview()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Play builds no nibs") }

    /// impl: PLAY-002 rule 8 — a timestamp above the pointer. No thumbnail: a
    /// second decoder is out of proportion for this player.
    private func installPreview() {
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        preview.textColor = .white
        preview.isHidden = true
        preview.setAccessibilityIdentifier(A11yID.hudSeekPreview.rawValue)
        addSubview(preview)
    }

    // MARK: - Geometry

    private var trackRect: NSRect {
        let height = (isHovered || isDragging) ? Self.activeHeight : Self.restHeight
        return NSRect(x: Self.inset, y: (bounds.height - height) / 2,
                      width: max(0, bounds.width - Self.inset * 2), height: height)
    }

    /// The single answer to "what time is under this x?", shared by click,
    /// drag and hover.
    private func positionMs(atX x: CGFloat) -> Int {
        let track = trackRect
        guard track.width > 0, state.lengthMs > 0 else { return 0 }
        let fraction = min(max(0, (x - track.minX) / track.width), 1)
        return Int(fraction * CGFloat(state.lengthMs))
    }

    // MARK: - Drawing

    /// impl: PLAY-002 rules 1-2, 10
    override func draw(_ dirtyRect: NSRect) {
        let track = trackRect
        let radius = track.height / 2
        // impl: PLAY-002 rule 10 — non-seekable media renders at 40 % opacity.
        let dim: CGFloat = state.isSeekable ? 1 : 0.4

        NSColor(white: 1, alpha: 0.3 * dim).setFill()
        NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()

        guard state.lengthMs > 0 else { return }
        let fraction = min(max(0, CGFloat(seeker.displayedPositionMs) / CGFloat(state.lengthMs)), 1)
        var elapsed = track
        elapsed.size.width = track.width * fraction
        NSColor.controlAccentColor.withAlphaComponent(dim).setFill()
        NSBezierPath(roundedRect: elapsed, xRadius: radius, yRadius: radius).fill()

        // impl: PLAY-002 rule 1 — the knob appears only on hover or drag.
        guard isHovered || isDragging else { return }
        let knob = NSRect(x: track.minX + elapsed.width - Self.knobDiameter / 2,
                          y: bounds.midY - Self.knobDiameter / 2,
                          width: Self.knobDiameter, height: Self.knobDiameter)
        NSColor.white.withAlphaComponent(dim).setFill()
        NSBezierPath(ovalIn: knob).fill()
    }

    /// Called by HUDView on every coalesced time event (PLAY-002 rule 3).
    func refresh() { needsDisplay = true }

    // MARK: - Tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow],
                                  owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        preview.isHidden = true
        needsDisplay = true
    }

    /// impl: PLAY-002 rule 8
    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        preview.stringValue = TimeFormat.string(
            forMs: positionMs(atX: point.x), lengthMs: state.lengthMs)
        preview.sizeToFit()
        preview.setFrameOrigin(NSPoint(x: point.x - preview.frame.width / 2,
                                       y: bounds.maxY - preview.frame.height))
        preview.isHidden = !state.isSeekable
        needsDisplay = true
    }

    // MARK: - Click and drag

    /// impl: PLAY-002 rules 5-7
    override func mouseDown(with event: NSEvent) {
        guard state.isSeekable else { return }
        isDragging = true
        onDragStateChange?(true)
        seeker.beginScrub()
        let point = convert(event.locationInWindow, from: nil)
        seeker.updateScrub(toMs: positionMs(atX: point.x))
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        let point = convert(event.locationInWindow, from: nil)
        seeker.updateScrub(toMs: positionMs(atX: point.x))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else {
            // A click that never became a drag still seeks (rule 5).
            let point = convert(event.locationInWindow, from: nil)
            seeker.seek(toMs: positionMs(atX: point.x), element: A11yID.hudSeekBar.rawValue)
            return
        }
        isDragging = false
        seeker.endScrub()
        onDragStateChange?(false)
        needsDisplay = true
    }

    /// impl: WIN-001 rule 9 — a drag that starts on the seek bar scrubs; it
    /// must never move the window.
    override var mouseDownCanMoveWindow: Bool { false }
}

/// impl: PLAY-002 rule 4 — `M:SS` under an hour, `H:MM:SS` at or over it,
/// chosen from the media's total length so labels do not change width
/// mid-playback.
enum TimeFormat {
    static func string(forMs ms: Int, lengthMs: Int) -> String {
        let total = max(0, ms) / 1000
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return lengthMs >= 3_600_000
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", total / 60, seconds)
    }
}
