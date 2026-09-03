// impl: PLAY-003 — Play's own volume, 0-125 %, persisted.
//
// Rule 5 is the subtle one: a level of 0 is *not* mute. The two are kept apart
// here and in the log, because conflating them makes "why is there no sound"
// undebuggable.

import Foundation

@MainActor
final class VolumeController {
    /// impl: PLAY-003 rule 1 — the headroom above 100 % is deliberate.
    static let maxPercent = 125
    private static let volumeKey = "audio.volume"
    private static let mutedKey = "audio.muted"

    private let player: MediaPlayer
    private let defaults: UserDefaults

    private(set) var percent: Int = 100
    private(set) var isMuted = false
    /// impl: PLAY-003 rule 4 — the exact level to restore on unmute.
    private var preMutePercent: Int = 100

    var onChange: (() -> Void)?

    init(player: MediaPlayer, defaults: UserDefaults = .standard) {
        self.player = player
        self.defaults = defaults
        restore()
    }

    /// impl: PLAY-003 rules 6-7 — a corrupt or out-of-range stored value falls
    /// back to 100 with a warning rather than reaching libvlc.
    private func restore() {
        let storedMuted = defaults.bool(forKey: Self.mutedKey)
        let stored = defaults.object(forKey: Self.volumeKey) as? Int
        if let stored, (0...Self.maxPercent).contains(stored) {
            percent = stored
        } else {
            if stored != nil {
                log(.playbackVolumeChanged, .warn, [
                    "reason": "storedValueOutOfRange", "stored": stored ?? -1, "toPercent": 100,
                ])
            }
            percent = 100
        }
        preMutePercent = percent
        isMuted = storedMuted
        apply(source: "restore", from: percent)
    }

    /// impl: PLAY-003 rule 3 — every route (slider, keys, scroll) lands here.
    func setVolume(percent target: Int, source: String, element: String) {
        let clamped = min(max(0, target), Self.maxPercent)
        let from = percent
        // impl: PLAY-003 rule 4 — raising the volume while muted unmutes, which
        // is what the gesture obviously means.
        if isMuted, clamped > 0 {
            isMuted = false
            log(.playbackMuteChanged, .info, ["muted": false, "restoredPercent": clamped])
        }
        percent = clamped
        preMutePercent = clamped
        apply(source: source, from: from, element: element)
    }

    func adjust(byPercent delta: Int, source: String, element: String) {
        setVolume(percent: percent + delta, source: source, element: element)
    }

    /// impl: PLAY-003 rules 4-5 — mute preserves the level exactly; it is not
    /// the same as setting the level to 0.
    func toggleMute(element: String) {
        isMuted.toggle()
        if isMuted { preMutePercent = percent } else { percent = preMutePercent }
        log(.playbackMuteChanged, .info, [
            "muted": isMuted, "restoredPercent": percent, "element": element,
        ])
        player.setMuted(isMuted)
        persist()
        onChange?()
    }

    private func apply(source: String, from: Int, element: String = "") {
        player.setVolume(percent: percent)
        player.setMuted(isMuted)
        log(.playbackVolumeChanged, .info, [
            "fromPercent": from, "toPercent": percent,
            "source": source, "element": element, "muted": isMuted,
        ])
        persist()
        onChange?()
    }

    /// impl: PLAY-003 rule 6
    private func persist() {
        defaults.set(percent, forKey: Self.volumeKey)
        defaults.set(isMuted, forKey: Self.mutedKey)
    }

    /// impl: PLAY-003 rule 6 — applied to each new media item, because libvlc
    /// resets the player's volume when the media changes.
    func reapplyToCurrentMedia() {
        player.setVolume(percent: percent)
        player.setMuted(isMuted)
    }
}
