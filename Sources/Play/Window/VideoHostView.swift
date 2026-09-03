// impl: WIN-001 rules 6, 9, 13 — the container handed to libvlc, plus the
// empty state and the "drag moves vs. drag scrubs" decision.

import AppKit
import PlayA11y

/// impl: WIN-001 rule 6 — the container that carries the corner radius. The
/// video view is its subview so `masksToBounds` has something to clip.
final class ContentRootView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        setAccessibilityIdentifier(A11yID.windowContentRoot.rawValue)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Play builds no nibs") }
}

/// impl: WIN-001 rule 13 / VLC-001 rule 16 — the NSView handed to
/// `libvlc_media_player_set_nsobject`. libvlc inserts its own GL-backed
/// subview here, so nothing else may draw into this view's layer.
final class VideoHostView: NSView {
    private let emptyStateLabel = NSTextField(labelWithString: "Drop a video, or ⌘O")

    private static let emptyBackdrop = NSColor(white: 0x11 / 255.0, alpha: 0.6).cgColor

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // impl: WIN-001 rule 13 — flat neutral backdrop, 60 % over the desktop.
        layer?.backgroundColor = Self.emptyBackdrop
        setAccessibilityIdentifier(A11yID.windowVideoView.rawValue)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        installEmptyState()
        // impl: MEDIA-001 rule 2 — without this registration the window is inert
        // to every drag, which is exactly the symptom it was reported with.
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Play builds no nibs") }

    /// impl: WIN-001 rule 13 — the only text ever drawn when no HUD is showing.
    private func installEmptyState() {
        emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyStateLabel.font = .systemFont(ofSize: 15, weight: .medium)
        emptyStateLabel.textColor = NSColor(white: 1, alpha: 0.55)
        emptyStateLabel.alignment = .center
        emptyStateLabel.setAccessibilityIdentifier(A11yID.windowEmptyStateHint.rawValue)
        addSubview(emptyStateLabel)
        NSLayoutConstraint.activate([
            emptyStateLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyStateLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    /// Called by AppDelegate on every PlaybackState change.
    func setEmptyStateVisible(_ visible: Bool) {
        emptyStateLabel.isHidden = !visible
        layer?.backgroundColor = visible ? Self.emptyBackdrop : NSColor.black.cgColor
    }

    /// impl: WIN-001 rule 13 / MEDIA-001 rule 9 — the hint has exactly two
    /// wordings, and the drag state is the only thing that switches between them.
    enum HintText: String {
        case dropAVideo = "Drop a video, or ⌘O"
        case releaseToPlay = "Release to play"
    }

    /// Called only by DropTarget, on drag enter and on every exit path.
    func setHintText(_ text: HintText) {
        emptyStateLabel.stringValue = text.rawValue
    }

    // MARK: - Dragging destination (MEDIA-001)

    /// impl: MEDIA-001 rule 2 — the drop target is the video host, so a drop
    /// anywhere on the picture counts. Set by AppDelegate at assembly.
    var dropTarget: DropTarget?

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropTarget?.draggingEntered(sender) ?? []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        // Re-asking on every update keeps the answer consistent with rule 10
        // without re-logging: DropTarget guards both the log and the highlight.
        dropTarget?.draggingEntered(sender) ?? []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropTarget?.draggingExited(sender)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        // The highlight must not outlive a drag that ended without a drop.
        dropTarget?.draggingExited(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropTarget?.performDragOperation(sender) ?? false
    }

    // impl: WIN-001 rules 4, 9 — `mouseDownCanMoveWindow` is a property of the
    // view that was hit, not a point query, so *which* points may drag is
    // decided by `HUDView.hitTest`: a press only reaches this view when that
    // returned nil, i.e. the point is a handle.
    //
    // This stays `true` for correctness, but it is not what moves the window:
    // `isMovableByWindowBackground` does nothing on a `.borderless` window
    // (WIN-001 rule 9.3a). `performDrag(with:)` below is what actually moves it.
    override var mouseDownCanMoveWindow: Bool { true }

    // MARK: - Pointer (CTRL-001, PLAY-001, PLAY-003)

    /// impl: CTRL-001 rule 4 — mouse movement reveals the HUD.
    var onMouseMoved: (() -> Void)?
    /// impl: CTRL-001 rule 7 — leaving the window hides it immediately.
    var onMouseExited: (() -> Void)?
    /// impl: PLAY-001 rule 5 — a single click toggles, resolved past the
    /// double-click interval so the fullscreen gesture wins its own event.
    var onSingleClick: (() -> Void)?
    /// impl: WIN-002 rule 1 — double-click toggles fullscreen.
    var onDoubleClick: (() -> Void)?
    /// impl: PLAY-003 rule 3 — scroll anywhere over the window adjusts volume.
    var onScroll: ((CGFloat) -> Void)?

    private var pointerTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTrackingArea { removeTrackingArea(pointerTrackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self)
        addTrackingArea(area)
        pointerTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) { onMouseMoved?() }
    override func mouseEntered(with event: NSEvent) { onMouseMoved?() }
    override func mouseExited(with event: NSEvent) { onMouseExited?() }

    /// impl: PLAY-003 rule 3 — ±2 % per notch.
    override func scrollWheel(with event: NSEvent) {
        onScroll?(event.scrollingDeltaY)
    }

    private var pendingSingleClick: DispatchWorkItem?

    /// impl: WIN-001 rule 9.6 / PLAY-001 rule 5 — where the press started, so a
    /// drag can be told from a click by the 3 pt the spec already named.
    private var pressOrigin: NSPoint?
    private var pressBecameDrag = false

    override func mouseDown(with event: NSEvent) {
        pressOrigin = event.locationInWindow
        pressBecameDrag = false
    }

    /// impl: WIN-001 rules 9, 9.3a, 9.6 — past the threshold the gesture is a
    /// window move, handed to the documented API. `performDrag(with:)` runs its
    /// own loop and consumes everything up to mouse-up, which is exactly why the
    /// threshold has to come first: without it every click would be a zero-pixel
    /// drag and PLAY-001 rule 5's click-to-toggle would never fire again.
    override func mouseDragged(with event: NSEvent) {
        guard let origin = pressOrigin, !pressBecameDrag else { return }
        let moved = hypot(event.locationInWindow.x - origin.x,
                          event.locationInWindow.y - origin.y)
        guard moved > Self.clickMovementTolerance else { return }
        pressBecameDrag = true
        window?.performDrag(with: event)
    }

    /// impl: PLAY-001 rule 5 — "movement < 3 pt", written down since the
    /// beginning and unimplemented until the drag needed it.
    private static let clickMovementTolerance: CGFloat = 3

    /// impl: PLAY-001 rule 5 / WIN-002 rule 1 — the single-click action is
    /// deferred past the double-click interval and cancelled if a second click
    /// arrives, so double-clicking to go fullscreen does not also toggle
    /// playback on the way.
    override func mouseUp(with event: NSEvent) {
        pendingSingleClick?.cancel()
        pendingSingleClick = nil

        // impl: WIN-001 rule 9.6 — a press that became a window move is not a
        // click. (Reached only if `performDrag` returns before mouse-up.)
        let wasDrag = pressBecameDrag
        pressOrigin = nil
        pressBecameDrag = false
        guard !wasDrag else { return }

        if event.clickCount >= 2 {
            onDoubleClick?()
            return
        }
        guard event.clickCount == 1 else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.pendingSingleClick = nil
            self?.onSingleClick?()
        }
        pendingSingleClick = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + NSEvent.doubleClickInterval, execute: work)
    }
}
