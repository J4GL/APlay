// impl: TRACK-002 — subtitle timing, fixed without leaving the film.
//
// Rule 3 is the whole reason this type exists separately: libvlc_video_set_spu_delay
// takes MICROSECONDS while every other time value in Play is milliseconds. The
// conversion happens in exactly one place, here, and is unit-tested — a 1000×
// error is silent and baffling to debug.

import Foundation

@MainActor
final class SubtitleDelayController {
    /// impl: TRACK-002 rule 2 — beyond a minute the subtitle file is simply the
    /// wrong one.
    nonisolated static let limitMs = 60_000

    private let player: MediaPlayer
    private let subtitles: SubtitleController

    private(set) var delayMs = 0

    /// Shows TRACK-002 rule 4's readout. Set by AppDelegate.
    var onReadout: ((String) -> Void)?

    init(player: MediaPlayer, subtitles: SubtitleController) {
        self.player = player
        self.subtitles = subtitles
    }

    // MARK: - Adjustment

    /// impl: TRACK-002 rules 1-2, 6 — H/J and their shifted variants.
    /// Called only by AppCommands.
    func step(byMs step: Int, element: String) {
        guard hasSubtitleTrack else {
            // rule 6 — a readout for something invisible is confusing.
            log(.tracksDelayIgnored, .info, ["reason": "noSubtitleTrack", "element": element])
            return
        }
        let from = delayMs
        let requested = from + step
        let clamped = min(Self.limitMs, max(-Self.limitMs, requested))
        if clamped != requested {
            log(.tracksDelayClamped, .info, ["atMs": clamped, "requestedMs": requested])
        }
        guard clamped != from else {
            // Already at the rail: the value did not move, so rule 8's
            // `changed` entry would be a lie. The readout still updates.
            onReadout?(Self.readout(forMs: clamped))
            return
        }
        delayMs = clamped
        apply()
        log(.tracksDelayChanged, .info, [
            "fromMs": from, "toMs": clamped, "stepMs": step, "element": element,
        ])
        onReadout?(Self.readout(forMs: clamped))
    }

    /// impl: TRACK-002 rule 1 — ⌥H. Called only by AppCommands.
    func reset(element: String) {
        guard hasSubtitleTrack else {
            log(.tracksDelayIgnored, .info, ["reason": "noSubtitleTrack", "element": element])
            return
        }
        let from = delayMs
        delayMs = 0
        apply()
        log(.tracksDelayReset, .info, ["fromMs": from, "element": element])
        onReadout?(Self.readout(forMs: 0))
    }

    /// impl: TRACK-002 rule 5 — per-media, and deliberately not persisted: a
    /// delay that silently applied to the next film would be undiagnosable.
    /// Called only by PlaybackState on a transition into `opening`.
    func resetForNewMedia() {
        delayMs = 0
    }

    /// impl: TRACK-002 rule 6 — "no subtitle track" covers both an empty list
    /// and a list with subtitles turned Off.
    private var hasSubtitleTrack: Bool {
        subtitles.selectedID != nil
    }

    /// impl: TRACK-002 rule 3 — THE ONLY ms→µs conversion in the codebase,
    /// kept as a pure function so it can be unit-tested as rule 3 demands.
    nonisolated static func microseconds(forMs ms: Int) -> Int64 { Int64(ms) * 1_000 }

    private func apply() {
        player.setSubtitleDelay(microseconds: Self.microseconds(forMs: delayMs))
    }

    // MARK: - Formatting

    /// impl: TRACK-002 rule 4 — `Subtitle delay +1.4 s`, sign included. A
    /// readout that drops the sign is worse than none.
    nonisolated static func readout(forMs ms: Int) -> String {
        guard ms != 0 else { return "Subtitle delay 0 s" }
        let sign = ms > 0 ? "+" : "−"
        let seconds = abs(Double(ms)) / 1000
        return String(format: "Subtitle delay %@%.1f s", sign, seconds)
    }
}
