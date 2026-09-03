// impl: TRACK-003 rules 4-9 — which audio track you listen to.
//
// The only caller of MediaPlayer.setAudioTrack, which is in turn the only caller
// of libvlc_audio_set_track (docs/call-graph.md sole-owner table).

import Foundation

@MainActor
final class AudioTrackController {
    private let player: MediaPlayer
    private let catalog: TrackCatalog

    /// impl: TRACK-003 rule 4 — `nil` is Off: the stream is deselected, which is
    /// not the same thing as mute (PLAY-003 rule 5) and stops the decode.
    private(set) var selectedID: Int32?
    private var userHasChosen = false

    var onChange: (() -> Void)?

    var tracks: [MediaTrack] { catalog.audio }

    /// impl: PREF-001 rule 4 — the audio language list and its name filter,
    /// separate from the subtitle one (rule 1).
    private let preferences: TrackPreferencesStore

    init(player: MediaPlayer, catalog: TrackCatalog, preferences: TrackPreferencesStore) {
        self.player = player
        self.catalog = catalog
        self.preferences = preferences
    }

    // MARK: - Selection

    /// impl: TRACK-003 rule 5 — applied and confirmed by reading back.
    func select(_ id: Int32?, source: TrackSelectionSource) {
        let target = id ?? -1
        guard player.setAudioTrack(id: target) else {
            log(.tracksAudioSelected, .warn, [
                "trackId": Int(target), "source": source.rawValue, "applied": false,
            ])
            return
        }
        let confirmed = player.audioTrackID
        selectedID = confirmed < 0 ? nil : confirmed
        if source.isUserChoice { userHasChosen = true }

        if selectedID == nil {
            log(.tracksAudioDisabled, .info, ["source": source.rawValue])
        } else {
            log(.tracksAudioSelected, .info, [
                "trackId": Int(confirmed),
                "name": name(of: selectedID),
                "source": source.rawValue,
                "applied": true,
            ])
        }
        onChange?()
    }

    /// impl: TRACK-003 rule 7 — `A` wraps through the real tracks and skips Off
    /// unless Off is the only entry there is. A single-track file therefore
    /// stays audible however many times `A` is pressed.
    func cycle() {
        let ring: [Int32?] = tracks.isEmpty ? [nil] : tracks.map { Optional($0.id) }
        let current = ring.firstIndex(where: { $0 == selectedID })
        let next = ring[((current ?? -1) + 1) % ring.count]
        log(.tracksAudioCycled, .info, [
            "fromTrackId": Int(selectedID ?? -1),
            "toTrackId": Int(next ?? -1),
            "count": ring.count,
        ])
        guard next != selectedID else { return }
        select(next, source: .cycle)
    }

    /// impl: TRACK-003 rule 6 — the preferred language, else libvlc's own first
    /// track. Unlike subtitles (TRACK-001 rule 8), falling back to the first
    /// track is right here: a film with no audio is not a reasonable default.
    /// impl: PREF-001 rule 12 — also called when the preference changes, so a
    /// setting takes effect on the film already playing; `userHasChosen` keeps a
    /// hand-picked track from being overridden.
    func applyDefault() {
        guard !userHasChosen, !tracks.isEmpty else { return }
        let chosen = TrackCatalog.firstPreferred(
            in: tracks, matching: preferences.preference(for: .audio)) ?? tracks[0]
        guard chosen.id != selectedID else { return }
        select(chosen.id, source: .default)
    }

    /// impl: TRACK-003 rule 9 — resets per media, and is not persisted across
    /// launches. Called only by PlaybackState on a transition into `opening`.
    func resetForNewMedia() {
        selectedID = nil
        userHasChosen = false
    }

    /// Called by TrackCatalog whenever the audio list actually changed.
    func catalogChanged() {
        if let selectedID, !tracks.contains(where: { $0.id == selectedID }) {
            self.selectedID = nil
        }
        applyDefault()
        onChange?()
    }

    func name(of id: Int32?) -> String {
        guard let id else { return "Off" }
        return tracks.first { $0.id == id }?.displayName ?? "Track \(id)"
    }
}
