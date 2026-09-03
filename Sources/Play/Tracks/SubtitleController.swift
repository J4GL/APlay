// impl: TRACK-001 rules 3, 5-12 — which subtitle track is showing.
//
// The only caller of MediaPlayer.setSubtitleTrack, which is in turn the only
// caller of libvlc_video_set_spu (docs/call-graph.md sole-owner table).

import Foundation

/// impl: TRACK-001 rule 15 / TRACK-003 rule 10 — why a track became selected.
enum TrackSelectionSource: String, Sendable {
    case user, `default`, externalDrop, cycle

    /// impl: PREF-001 rule 12 — "a track the user picked by hand, with `S`, `A`,
    /// the HUD menu or the menu bar, is never overridden by a later settings
    /// change". `cycle` **is** picking by hand: it is what `S` and `A` do.
    ///
    /// Only `.user` counted before, so pressing `A` and then editing the
    /// preferences moved the track back under the user. PREF-001's own
    /// hand-picked scenario is what caught it.
    var isUserChoice: Bool {
        switch self {
        case .user, .cycle: true
        case .default, .externalDrop: false
        }
    }
}

@MainActor
final class SubtitleController {
    private let player: MediaPlayer
    private let catalog: TrackCatalog

    /// impl: TRACK-001 rule 3 — Off is a first-class choice, so `nil` is a
    /// selection and not the absence of one.
    private(set) var selectedID: Int32?

    /// impl: TRACK-001 rule 8 — the default is applied once per media, and never
    /// again over a choice the user has made.
    private var userHasChosen = false

    /// Redraws the menu's check mark. Set by AppDelegate.
    var onChange: (() -> Void)?

    /// impl: TRACK-001 rule 11 — a subtitle file that fails to load reports
    /// through MEDIA-002's path. Set by AppDelegate.
    var onFailure: ((MediaFailure, URL) -> Void)?

    /// impl: TRACK-001 rule 3 — the list as the menu shows it: Off first, always.
    var tracks: [MediaTrack] { catalog.subtitles }

    /// impl: PREF-001 rule 4 — the subtitle language list and its name filter.
    private let preferences: TrackPreferencesStore

    init(player: MediaPlayer, catalog: TrackCatalog, preferences: TrackPreferencesStore) {
        self.player = player
        self.catalog = catalog
        self.preferences = preferences
    }

    // MARK: - Selection

    /// impl: TRACK-001 rule 5 — applied, then **confirmed** by reading libvlc
    /// back. The check mark follows the confirmed value, never the request.
    func select(_ id: Int32?, source: TrackSelectionSource) {
        let target = id ?? -1
        guard player.setSubtitleTrack(id: target) else {
            log(.tracksSubtitleSelected, .warn, [
                "trackId": Int(target), "source": source.rawValue, "applied": false,
            ])
            return
        }
        let confirmed = player.subtitleTrackID
        selectedID = confirmed < 0 ? nil : confirmed
        if source.isUserChoice { userHasChosen = true }

        log(.tracksSubtitleSelected, .info, [
            "trackId": Int(confirmed),
            "name": name(of: selectedID),
            "source": source.rawValue,
            "applied": true,
        ])
        onChange?()
    }

    /// impl: TRACK-001 rule 7 — `S` cycles to the next track, wrapping *through*
    /// Off. A one-element cycle (Off only) is the case naive modulo arithmetic
    /// gets wrong, so the ring is built explicitly.
    func cycle() {
        let ring: [Int32?] = [nil] + tracks.map { Optional($0.id) }
        let current = ring.firstIndex(where: { $0 == selectedID }) ?? 0
        let next = ring[(current + 1) % ring.count]
        log(.tracksSubtitleCycled, .info, [
            "fromTrackId": Int(selectedID ?? -1),
            "toTrackId": Int(next ?? -1),
            "count": ring.count,
        ])
        select(next, source: .cycle)
    }

    /// impl: TRACK-001 rule 8 — a language match or Off. Auto-enabling a
    /// Hungarian track on an English film because it is track 1 is a worse
    /// default than none. Called when the ES list settles.
    /// impl: PREF-001 rule 12 — also called when the preference changes, so a
    /// setting takes effect on the film already playing. `userHasChosen` is what
    /// keeps that safe: a default never outranks a decision.
    func applyDefault() {
        guard !userHasChosen else { return }
        let preference = preferences.preference(for: .subtitle)
        let preferred = TrackCatalog.firstPreferred(in: tracks, matching: preference)
        guard preferred?.id != selectedID else {
            // impl: TRACK-001 rule 16 — "no language matched, so Off" is a
            // decision and has to say so. Silent, it is indistinguishable from a
            // preference that was never consulted, which is exactly how a
            // mis-mapped language code stayed invisible: the log listed the
            // tracks, listed the preference, then said nothing.
            if preferred == nil, !tracks.isEmpty {
                log(.tracksSubtitleSelected, .info, [
                    "trackId": -1, "name": "Off", "source": TrackSelectionSource.default.rawValue,
                    "applied": true, "reason": "noLanguageMatch",
                    "wanted": preference.languages.isEmpty
                        ? LanguageCode.systemPreferred() : preference.languages,
                    "offered": tracks.map { TrackCatalog.alpha2($0.language) ?? "und" },
                ])
            }
            return
        }
        select(preferred?.id, source: .default)
    }

    /// impl: TRACK-001 rule 6 — selection resets on each new media item.
    /// Called only by PlaybackState on a transition into `opening`.
    func resetForNewMedia() {
        selectedID = nil
        userHasChosen = false
    }

    // MARK: - External files

    /// impl: TRACK-001 rules 9-12 — attaching never interrupts playback:
    /// position, status and volume are untouched by `add_slave`.
    /// Called only by FileOpener (drop, and the sidecar scan).
    func addExternal(url: URL, select shouldSelect: Bool) {
        let stem = url.deletingPathExtension().lastPathComponent
        guard player.addSubtitleSlave(url: url, select: shouldSelect) else {
            log(.tracksSubtitleExternalFailed, .error, ["stem": stem])
            onFailure?(.noPlayableTrack, url)
            return
        }
        catalog.registerExternal(stem: stem)
        log(.tracksSubtitleExternalAdded, .info, ["stem": stem, "selected": shouldSelect])
        if shouldSelect {
            // libvlc selects the slave itself; record what it actually chose so
            // the menu's check mark and `selectedID` cannot drift from libvlc.
            userHasChosen = true
            let confirmed = player.subtitleTrackID
            selectedID = confirmed < 0 ? nil : confirmed
            log(.tracksSubtitleSelected, .info, [
                "trackId": Int(confirmed), "name": stem,
                "source": TrackSelectionSource.externalDrop.rawValue, "applied": true,
            ])
            onChange?()
        }
    }

    // MARK: - Catalog

    /// Called by TrackCatalog whenever the subtitle list actually changed.
    func catalogChanged() {
        // A track that disappeared must not stay selected in the menu.
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
