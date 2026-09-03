// impl: WIN-001 rules 1-5, 11 — the window shell.
//
// A borderless NSWindow loses four things the system normally gives away:
// becoming key, dragging, closing, and rounded corners. Rules 1-4 restore the
// first three here; WindowShapeController handles the fourth.

import AppKit

final class BorderlessWindow: NSWindow {
    /// impl: WIN-001 rule 2 — borderless windows return false by default and
    /// would never receive a key event. Every CTRL-002 shortcut depends on this.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   // impl: WIN-001 rule 1 — `.resizable` keeps the eight invisible
                   // edge regions alive; without it the window is a fixed size.
                   // `.miniaturizable` and `.closable` draw nothing without a
                   // titlebar and are here only so `performMiniaturize` and
                   // `performClose` work at all: both are no-ops on a window
                   // whose mask lacks the flag, which is why ⌘W and the HUD's ✕
                   // silently did nothing.
                   styleMask: [.borderless, .resizable, .miniaturizable, .closable],
                   backing: .buffered,
                   defer: false)

        // impl: WIN-001 rule 3
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true

        // impl: WIN-001 rule 4 — the whole picture is the drag handle.
        isMovableByWindowBackground = true

        // impl: WIN-001-S2 — clamps at 320 x 180 and goes no smaller.
        contentMinSize = NSSize(width: 320, height: 180)

        collectionBehavior = [.fullScreenPrimary, .managed]
        isReleasedWhenClosed = false
    }

    /// impl: CTRL-002 rule 6 — set by AppDelegate. A chromeless app has no menu
    /// bar, so `BorderlessWindow` is the only dispatcher for every binding,
    /// `⌘` ones included.
    var commands: AppCommands?

    /// impl: CTRL-002 rules 5, 8 — one lookup, and anything unhandled goes to
    /// `super` unlogged rather than being swallowed.
    override func keyDown(with event: NSEvent) {
        guard commands?.handle(event) == true else {
            super.keyDown(with: event)
            return
        }
    }
}
