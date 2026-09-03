// impl: CTRL-001 rules 4-7 — when the HUD is on screen.
//
// The suppression set is a set of *reasons*, not a boolean, so the log can say
// why the HUD refused to hide. CTRL-001-S2 asserts every suppress has exactly
// one matching release.

import AppKit

/// impl: CTRL-001 rule 5
enum HUDSuppression: String, CaseIterable, Sendable {
    case notPlaying, pointerInsideHUD, menuOpen, queuePanelOpen, dragInProgress, transientVisible
}

enum HUDShowTrigger: String, Sendable {
    /// impl: CTRL-004 rule 14 — `menu` exists because a command invoked from the
    /// menu bar must still show its effect, even though the pointer never
    /// touched the video.
    case mouseMove, key, stateChange, menu
}

@MainActor
final class AutoHideController {
    /// impl: CTRL-001 rule 5
    private static let idleDelay: TimeInterval = 2.5

    private var suppressions: Set<HUDSuppression> = []
    private var timer: Timer?
    private(set) var isVisible = false

    /// Set by AppDelegate to the HUD's fade in/out.
    var onVisibilityChange: ((Bool) -> Void)?

    // MARK: - Activity

    /// impl: CTRL-001 rule 4 — mouse movement, HUD-visible keys, and any state
    /// change reveal the HUD and restart the idle timer.
    func noteActivity(trigger: HUDShowTrigger) {
        if !isVisible {
            isVisible = true
            log(.hudShown, .info, ["trigger": trigger.rawValue])
            onVisibilityChange?(true)
            CursorVisibility.setHidden(false)
        }
        restartTimer()
    }

    /// impl: CTRL-001 rule 7 — leaving the window hides immediately; the user
    /// has clearly looked away.
    func pointerExitedWindow() {
        guard isVisible, suppressions.isEmpty else { return }
        hide(trigger: "mouseExit")
    }

    // MARK: - Suppression

    func suppress(_ reason: HUDSuppression) {
        guard !suppressions.contains(reason) else { return }
        suppressions.insert(reason)
        // impl: CTRL-001 rule 5 — logged when the suppression is *added*, with
        // the single reason the spec's scenarios assert. A suppressed HUD has no
        // idle timer to fire, so an entry written only at fire time is an entry
        // that never appears — which is how LIST-002-S3 caught this.
        log(.hudAutoHideSuppressed, .info, ["reason": reason.rawValue, "when": "requested"])
        timer?.invalidate()
        timer = nil
    }

    func release(_ reason: HUDSuppression) {
        guard suppressions.remove(reason) != nil else { return }
        if suppressions.isEmpty, isVisible { restartTimer() }
    }

    // MARK: - Timer

    private func restartTimer() {
        timer?.invalidate()
        timer = nil
        guard suppressions.isEmpty else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.idleDelay, repeats: false) { _ in
            MainActor.assumeIsolated { self.idleFired() }
        }
    }

    private func idleFired() {
        timer = nil
        // impl: CTRL-001 rule 5 — re-check at fire time. Only reachable when a
        // suppression lands between scheduling and firing; `suppress` cancels
        // the timer otherwise.
        guard suppressions.isEmpty else {
            log(.hudAutoHideSuppressed, .debug, [
                "reason": suppressions.map(\.rawValue).sorted().joined(separator: ","),
                "when": "idleFired",
            ])
            return
        }
        hide(trigger: "idle")
    }

    private func hide(trigger: String) {
        isVisible = false
        timer?.invalidate()
        timer = nil
        log(.hudHidden, .info, ["trigger": trigger])
        onVisibilityChange?(false)
        CursorVisibility.setHidden(true)
    }
}
