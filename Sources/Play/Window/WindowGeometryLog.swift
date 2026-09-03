// impl: WIN-001 rule 14 — coalesced move/resize logging.
//
// A drag emits hundreds of NSWindowDidMove notifications; logging each one
// would bury every other event in the session file. At most one per 200 ms,
// and the final position is always emitted so a test can assert the end state.

import AppKit

@MainActor
final class WindowGeometryLog: NSObject, NSWindowDelegate {
    private static let coalesceInterval: TimeInterval = 0.2

    private var lastMoveLog: Date = .distantPast
    private var lastResizeLog: Date = .distantPast
    private var pendingFinal: DispatchWorkItem?

    /// Called by AppDelegate when the window closes, so the app can terminate.
    var onWindowWillClose: (() -> Void)?

    /// impl: WIN-002 rule 2 — forwarded to FullscreenController, which owns the
    /// corner-radius animation. This class stays the window's only delegate.
    var fullscreen: FullscreenController?

    /// impl: WIN-001 rule 14 — logged once at creation.
    ///
    /// The style mask is reported because rule 1 makes claims about it that
    /// AppKit is free to ignore: a borderless window silently drops the
    /// titlebar-button flags, and WIN-001-H1 asserts what actually survived
    /// rather than what was asked for.
    func logCreated(_ window: NSWindow) {
        var payload = Self.framePayload(window)
        payload["styleMask"] = Int(window.styleMask.rawValue)
        payload["closable"] = window.styleMask.contains(.closable)
        payload["miniaturizable"] = window.styleMask.contains(.miniaturizable)
        log(.windowCreated, .info, payload)
    }

    // MARK: - NSWindowDelegate

    func windowDidMove(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        coalesce(&lastMoveLog, event: .windowMoved, window: window)
    }

    func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        coalesce(&lastResizeLog, event: .windowResized, window: window)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        log(.windowBecameKey, .info, Self.framePayload(window))
    }

    func windowDidResignKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        log(.windowResignedKey, .info, Self.framePayload(window))
    }

    // impl: WIN-002 rule 2
    func windowWillEnterFullScreen(_ notification: Notification) {
        fullscreen?.windowWillEnterFullScreen()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        fullscreen?.windowDidExitFullScreen()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        pendingFinal?.cancel()
        log(.windowClosed, .info, Self.framePayload(window))
        onWindowWillClose?()
    }

    // MARK: - Coalescing

    private func coalesce(_ last: inout Date, event: LogEvent, window: NSWindow) {
        let now = Date()
        let payload = Self.framePayload(window)
        if now.timeIntervalSince(last) >= Self.coalesceInterval {
            last = now
            log(event, .debug, payload)
        }
        // impl: WIN-001 rule 14 — the final position is always emitted.
        pendingFinal?.cancel()
        let final = DispatchWorkItem { log(event, .info, payload.merging(["final": true]) { a, _ in a }) }
        pendingFinal = final
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.coalesceInterval, execute: final)
    }

    private static func framePayload(_ window: NSWindow) -> [String: Any] {
        let f = window.frame
        return ["x": Int(f.origin.x), "y": Int(f.origin.y),
                "w": Int(f.size.width), "h": Int(f.size.height)]
    }
}
