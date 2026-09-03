// impl: WIN-002 rules 1-3, 8 — native fullscreen on a borderless window.
//
// Rung 1 of rule 3-4: `.fullScreenPrimary` + `toggleFullScreen`. The manual
// fill of rule 4 is the documented fallback and is not written until WIN-002-H1
// actually fails — an unused fallback is code that rots.

import AppKit

@MainActor
final class FullscreenController: NSObject {
    private unowned let window: NSWindow
    private unowned let contentRoot: NSView

    private(set) var isFullscreen = false

    /// impl: WIN-003 rule 14 — set by AppDelegate. A ratio-locked window cannot
    /// fill a display, so the lock is let go of here and taken back on exit.
    var aspectRatio: AspectRatioLock?

    init(window: NSWindow, contentRoot: NSView) {
        self.window = window
        self.contentRoot = contentRoot
    }

    /// impl: WIN-002 rule 1 — F, double-click, and the HUD button all land here.
    func toggle(element: String) {
        window.toggleFullScreen(nil)
        log(isFullscreen ? .windowFullscreenExit : .windowFullscreenEnter, .info, [
            "path": "native", "element": element,
            "displayID": Int(window.screen?.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 ?? 0),
        ])
    }

    /// impl: WIN-002 rule 1 — Esc exits and never enters.
    func exit(element: String) {
        guard isFullscreen else { return }
        toggle(element: element)
    }

    // MARK: - NSWindowDelegate hooks, forwarded by WindowGeometryLog

    /// impl: WIN-002 rule 2 / WIN-001 rule 7 — rounded corners against the
    /// black of a fullscreen display would read as notches.
    func windowWillEnterFullScreen() {
        isFullscreen = true
        WindowShapeController.setCornerRadius(0, on: contentRoot, animated: true)
        // impl: WIN-003 rule 14 — before AppKit picks the fullscreen size, not
        // after: a lock still in place makes it choose the largest rectangle of
        // that ratio and leave the desktop showing on two edges.
        aspectRatio?.suspendForFullscreen()
    }

    func windowDidExitFullScreen() {
        isFullscreen = false
        WindowShapeController.setCornerRadius(
            WindowShapeController.cornerRadius, on: contentRoot, animated: true)
        // impl: WIN-003 rules 14-15 — including a ratio that arrived while the
        // lock was suspended.
        aspectRatio?.restoreAfterFullscreen()
        log(.windowFullscreenRestored, .info, [
            "x": Int(window.frame.origin.x), "y": Int(window.frame.origin.y),
            "w": Int(window.frame.width), "h": Int(window.frame.height),
        ])
    }
}
