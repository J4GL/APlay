// impl: CTRL-001 rule 6 — the cursor hides with the HUD and returns with it.
//
// A visible arrow floating over a hidden HUD is the detail that makes a
// fullscreen player feel unfinished.

import AppKit

@MainActor
enum CursorVisibility {
    /// Called only by AutoHideController, on the same edges as the HUD fade.
    static func setHidden(_ hidden: Bool) {
        if hidden {
            NSCursor.setHiddenUntilMouseMoves(true)
        } else {
            NSCursor.setHiddenUntilMouseMoves(false)
        }
    }
}
