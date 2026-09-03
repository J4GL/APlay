// impl: PLAY-001 rules 3, 5-7 — the only caller of MediaPlayer's transport.
//
// Rule 3 is the important one: nothing here sets `status`. Every method asks
// libvlc and lets the event come back, so the UI stays honest when libvlc
// refuses.

import Foundation

@MainActor
final class TransportController {
    private let player: MediaPlayer
    private let state: PlaybackState

    init(player: MediaPlayer, state: PlaybackState) {
        self.player = player
        self.state = state
    }

    /// impl: PLAY-001 rule 5 — Space, the HUD button, and a single video click
    /// all land here. Rule 6 governs what happens outside playing/paused.
    func toggle(element: String) {
        let before = state.status
        switch before {
        case .playing:
            log(.playbackTransportToggle, .info, [
                "element": element, "statusBefore": before.name,
                "statusAfter": "paused", "positionMs": state.positionMs,
            ])
            pause(element: element)
        case .paused:
            log(.playbackTransportToggle, .info, [
                "element": element, "statusBefore": before.name,
                "statusAfter": "playing", "positionMs": state.positionMs,
            ])
            play(element: element)
        case .ended:
            // impl: PLAY-001 rule 6 — toggling in `ended` restarts from 0.
            log(.playbackTransportToggle, .info, [
                "element": element, "statusBefore": before.name,
                "statusAfter": "opening", "positionMs": 0,
            ])
            player.setTime(ms: 0)
            player.play()
        case .idle, .failed:
            // impl: PLAY-001 rule 6 — nothing to toggle, and no libvlc call is
            // made, which is what PLAY-001-S1 asserts.
            log(.playbackTransportIgnored, .info, ["element": element, "status": before.name])
        case .opening:
            log(.playbackTransportIgnored, .info, ["element": element, "status": before.name])
        }
    }

    /// impl: PLAY-001 rule 3 — request only; `status` changes when the event returns.
    func play(element: String) {
        log(.playbackTransportPlay, .info, [
            "element": element, "statusBefore": state.status.name,
            "positionMs": state.positionMs,
        ])
        if state.status == .paused { player.resume() } else { player.play() }
    }

    func pause(element: String) {
        log(.playbackTransportPause, .info, [
            "element": element, "statusBefore": state.status.name,
            "positionMs": state.positionMs,
        ])
        player.pause()
    }

    /// impl: PLAY-001 rule 7 — reachable only by closing the current item (⌘.).
    /// There is no stop button in the HUD.
    func stop(element: String) {
        log(.playbackTransportStop, .info, [
            "element": element, "statusBefore": state.status.name,
            "positionMs": state.positionMs,
        ])
        player.stop()
        state.transition(to: .idle)
    }
}
