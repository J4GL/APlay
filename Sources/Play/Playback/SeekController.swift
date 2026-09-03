// impl: PLAY-002 rules 5-12 — the only place that moves playback position.
//
// The throttle in rule 6 is the point of this file: issuing a seek per
// mouse-moved event floods libvlc and makes scrubbing lurch.

import Foundation
import PlayA11y

@MainActor
final class SeekController {
    private let player: MediaPlayer
    private let state: PlaybackState

    /// impl: PLAY-002 rule 6 — one libvlc call per 100 ms while scrubbing.
    private static let scrubThrottle: TimeInterval = 0.1
    private var lastScrubIssue: Date = .distantPast
    /// impl: PLAY-002 rule 7 — the internal pause, which deliberately does not
    /// touch `PlaybackState.status`.
    private var resumeAfterScrub = false

    private(set) var scrubPositionMs: Int?

    /// impl: PLAY-004 rule 8 — set by AppDelegate; "any seek" dismisses a
    /// visible resume toast.
    var onSeekOccurred: (() -> Void)?

    init(player: MediaPlayer, state: PlaybackState) {
        self.player = player
        self.state = state
    }

    /// The position the UI should draw: the scrub position while dragging,
    /// otherwise the engine's own.
    var displayedPositionMs: Int { scrubPositionMs ?? state.positionMs }

    // MARK: - Discrete seeks

    /// impl: PLAY-002 rule 5 — a click on the bar seeks there immediately.
    func seek(toMs target: Int, element: String) {
        guard canSeek(element: element) else { return }
        onSeekOccurred?()
        let clamped = clamp(target)
        log(.playbackSeekClick, .info, [
            "fromMs": state.positionMs, "toMs": clamped,
            "lengthMs": state.lengthMs, "element": element,
        ])
        player.setTime(ms: clamped)
        state.applySeekedPosition(clamped)
    }

    /// impl: PLAY-002 rule 9 — keyboard nudges clamp and never wrap.
    func nudge(byMs delta: Int, element: String) {
        guard canSeek(element: element) else { return }
        onSeekOccurred?()
        let clamped = clamp(state.positionMs + delta)
        log(.playbackSeekKeyboard, .info, [
            "deltaMs": delta, "fromMs": state.positionMs, "toMs": clamped,
            "lengthMs": state.lengthMs, "element": element,
        ])
        player.setTime(ms: clamped)
        state.applySeekedPosition(clamped)
    }

    // MARK: - Scrubbing

    /// impl: PLAY-002 rule 7 — pause internally so audio does not stutter, and
    /// leave `status` alone: the user did not press pause.
    func beginScrub() {
        guard canSeek(element: A11yID.hudSeekBar.rawValue) else { return }
        onSeekOccurred?()
        scrubPositionMs = state.positionMs
        if state.status == .playing {
            resumeAfterScrub = true
            player.pause()
            log(.playbackSeekScrubPause, .debug, ["paused": true])
        }
    }

    /// impl: PLAY-002 rule 6 — throttled to one libvlc call per 100 ms.
    func updateScrub(toMs target: Int) {
        guard scrubPositionMs != nil else { return }
        let clamped = clamp(target)
        scrubPositionMs = clamped
        let now = Date()
        guard now.timeIntervalSince(lastScrubIssue) >= Self.scrubThrottle else { return }
        lastScrubIssue = now
        player.setTime(ms: clamped)
        log(.playbackSeekScrub, .debug, [
            "toMs": clamped, "lengthMs": state.lengthMs, "final": false,
        ])
    }

    /// impl: PLAY-002 rule 6 — the final position is always issued on release.
    func endScrub() {
        guard let target = scrubPositionMs else { return }
        scrubPositionMs = nil
        player.setTime(ms: target)
        // impl: PLAY-002 rule 3 — without this the bar snaps back to the old
        // position on release while paused, since no time event follows.
        state.applySeekedPosition(target)
        log(.playbackSeekScrub, .info, [
            "toMs": target, "lengthMs": state.lengthMs, "final": true,
        ])
        if resumeAfterScrub {
            resumeAfterScrub = false
            player.resume()
            log(.playbackSeekScrubPause, .debug, ["paused": false])
        }
    }

    // MARK: - Preconditions

    /// impl: PLAY-002 rules 10, 12 — refused with a reason, never attempted.
    private func canSeek(element: String) -> Bool {
        switch state.status {
        case .idle, .failed:
            log(.playbackSeekRejected, .info, ["reason": "noMedia", "element": element])
            return false
        default: break
        }
        guard player.isSeekable else {
            log(.playbackSeekRejected, .info, ["reason": "notSeekable", "element": element])
            return false
        }
        return true
    }

    /// impl: PLAY-002 rule 9 — clamps to `[0, length − 100 ms]`, so a keyboard
    /// nudge cannot trip end-of-media and skip to the next item.
    private func clamp(_ ms: Int) -> Int {
        guard state.lengthMs > 0 else { return max(0, ms) }
        return min(max(0, ms), max(0, state.lengthMs - 100))
    }
}
