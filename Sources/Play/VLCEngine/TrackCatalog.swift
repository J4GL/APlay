// impl: TRACK-001 rules 1-4 · TRACK-003 rules 1-3 — the subtitle and audio
// track lists, rebuilt from ES events.
//
// Rule 1 is the reason this is event-driven rather than a snapshot taken at
// `playing`: MKVs declare subtitle tracks late in the container, so a list read
// once when playback starts is empty on exactly the files that need it.

import Foundation

/// impl: TRACK-001 rule 2 / TRACK-003 rule 2 — a track as the user sees it.
struct MediaTrack: Equatable, Sendable {
    let id: Int32
    let displayName: String
    let language: String?
    let channels: Int
    let isExternal: Bool
    /// impl: PREF-001 rule 6 — libvlc's own strings, kept for the name filter
    /// to match against. `displayName` is the *cooked* name: rule 2 discards a
    /// generic `listName` and falls back to the localised language, so a track
    /// carrying only `lang=fra` is called "French" and the word "forced" that
    /// libvlc did report would be unmatchable without this.
    var searchText: String = ""

    /// impl: PREF-001 rule 6 — the filter matches the shown name *and* the raw
    /// description, case- and diacritic-insensitively.
    nonisolated func matches(nameFilter: String) -> Bool {
        let filter = nameFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !filter.isEmpty else { return false }
        return (displayName + " " + searchText).localizedCaseInsensitiveContains(filter)
    }
}

@MainActor
final class TrackCatalog {
    private let player: MediaPlayer

    private(set) var subtitles: [MediaTrack] = []
    private(set) var audio: [MediaTrack] = []

    /// Set by SubtitleController and AudioTrackController at assembly; called
    /// after every rebuild that actually changed a list.
    var onSubtitlesChanged: (() -> Void)?
    var onAudioChanged: (() -> Void)?

    /// impl: TRACK-001 rule 12 — external tracks are labelled with their file's
    /// stem, which is the only name that distinguishes them from embedded ones.
    /// Recorded by SubtitleController.addExternal, cleared on each new media.
    private var externalStems: [String] = []

    init(player: MediaPlayer) {
        self.player = player
    }

    /// Called only by SubtitleController.addExternal.
    func registerExternal(stem: String) {
        guard !externalStems.contains(stem) else { return }
        externalStems.append(stem)
    }

    /// impl: TRACK-001 rule 6 / TRACK-003 rule 9 — per-media state. Called only
    /// by PlaybackState on a transition into `opening`.
    func resetForNewMedia() {
        externalStems.removeAll()
        subtitles = []
        audio = []
    }

    /// impl: TRACK-001 rule 1 / TRACK-003 rule 1 — called only by PlaybackState
    /// on `ESAdded` / `ESDeleted`.
    func rebuild() {
        let newSubtitles = Self.name(player.subtitleTracks(), externalStems: externalStems)
        if newSubtitles != subtitles {
            subtitles = newSubtitles
            log(.tracksSubtitleListChanged, .info, Self.listPayload(newSubtitles))
            onSubtitlesChanged?()
        }

        let newAudio = Self.name(player.audioTracks(), externalStems: [])
        if newAudio != audio {
            audio = newAudio
            log(.tracksAudioListChanged, .info, Self.listPayload(newAudio))
            onAudioChanged?()
        }
    }

    /// impl: TRACK-001 rule 15 / TRACK-003 rule 10 — the codes as libvlc
    /// reported them, beside the two-letter form they resolve to. A preference
    /// that matches nothing is otherwise unreadable from the trace: the log
    /// listed the tracks, listed the preference, and left the mismatch between
    /// them invisible.
    nonisolated private static func listPayload(_ tracks: [MediaTrack]) -> [String: Any] {
        let ids: [Int] = tracks.map { Int($0.id) }
        let names: [String] = tracks.map(\.displayName)
        let languages: [String] = tracks.map { $0.language ?? "und" }
        let resolved: [String] = tracks.map { alpha2($0.language) ?? "und" }
        return ["count": tracks.count, "ids": ids, "names": names,
                "languages": languages, "alpha2": resolved]
    }

    // MARK: - Naming

    /// impl: TRACK-001 rules 2, 4, 12 · TRACK-003 rules 2-3 — the whole naming
    /// policy, pure and therefore unit-testable without a live libvlc.
    nonisolated static func name(_ raw: [MediaPlayer.RawTrack], externalStems: [String]) -> [MediaTrack] {
        var tracks: [MediaTrack] = raw.enumerated().map { index, track in
            // rule 12 — libvlc names an added slave after its file, so a stem we
            // registered appearing in either name is what identifies it.
            let stem = externalStems.first {
                track.listName.localizedCaseInsensitiveContains($0)
                    || (track.title?.localizedCaseInsensitiveContains($0) ?? false)
            }
            return MediaTrack(
                id: track.id,
                displayName: stem ?? baseName(track, index: index),
                language: track.language,
                channels: track.channels,
                isExternal: stem != nil,
                // impl: PREF-001 rule 6 — libvlc's raw strings, before rule 2's
                // naming policy throws the generic-looking ones away.
                searchText: [track.title, track.listName]
                    .compactMap { $0 }
                    .filter { !$0.isEmpty }
                    .joined(separator: " "))
        }
        tracks = disambiguate(tracks)
        return tracks
    }

    /// impl: TRACK-001 rule 2 — title, else the localised language name, else
    /// "Track <n>". A bare `spa` is not a useful thing to show a person.
    /// impl: TRACK-003 rule 2 — the channel layout is appended when it is known
    /// and above stereo, because that is the real difference between two
    /// same-language audio tracks.
    nonisolated private static func baseName(_ track: MediaPlayer.RawTrack, index: Int) -> String {
        var name = track.title?.trimmingCharacters(in: .whitespaces)
        if name?.isEmpty ?? true { name = localizedLanguage(track.language) }
        if name?.isEmpty ?? true, !track.listName.isEmpty, !isGenericListName(track.listName) {
            name = track.listName
        }
        var resolved = name?.isEmpty == false ? name! : "Track \(index + 1)"
        if let layout = channelLayout(track.channels) { resolved += " \(layout)" }
        return resolved
    }

    /// libvlc's own fallback names ("Track 1", "Track 1 - [English]") carry no
    /// information our own rule-2 policy has not already produced.
    nonisolated private static func isGenericListName(_ name: String) -> Bool {
        name.range(of: #"^Track \d+"#, options: .regularExpression) != nil
    }

    nonisolated static func localizedLanguage(_ code: String?) -> String? {
        guard let code, !code.isEmpty, code != "und" else { return nil }
        return Locale.current.localizedString(forLanguageCode: code)
    }

    /// impl: TRACK-003 rule 2 — only above stereo; "English 2.0" would be noise.
    nonisolated static func channelLayout(_ channels: Int) -> String? {
        switch channels {
        case 6: "5.1"
        case 7: "6.1"
        case 8: "7.1"
        case let n where n > 2: "\(n).0"
        default: nil
        }
    }

    /// impl: TRACK-001 rule 4 — two English tracks (forced and full) must be
    /// distinguishable, so duplicates gain a trailing index.
    nonisolated static func disambiguate(_ tracks: [MediaTrack]) -> [MediaTrack] {
        var counts: [String: Int] = [:]
        for track in tracks { counts[track.displayName, default: 0] += 1 }
        var seen: [String: Int] = [:]
        return tracks.map { track in
            guard counts[track.displayName, default: 0] > 1 else { return track }
            let ordinal = seen[track.displayName, default: 0] + 1
            seen[track.displayName] = ordinal
            let suffix = ordinal == 1 ? "" : " \(ordinal)"
            return MediaTrack(id: track.id,
                              displayName: track.displayName + suffix,
                              language: track.language,
                              channels: track.channels,
                              isExternal: track.isExternal,
                              searchText: track.searchText)
        }
    }

    /// impl: TRACK-001 rule 8 / TRACK-003 rule 6 / PREF-001 rules 4-5, 8 — the
    /// language-preference match both defaults are decided by.
    ///
    /// The preference list is walked **in the user's order**, not the track
    /// order: on a dual-audio film someone whose first language is French must
    /// get French, even though the English stream happens to come first in the
    /// container. Matching by track order picked English here, which is exactly
    /// what TRACK-003-H2 forbids.
    ///
    /// PREF-001 rule 5 — the name filter is a *tie-breaker*, not a requirement.
    /// When no track of the winning language matches it, the first track of that
    /// language is still returned: the filter never skips to the next language
    /// and never lands on Off. A tie-breaker that can lose the tie is a trap.
    ///
    /// Pure on purpose (rule 8): this is what makes TRACK-003-H2 assertable
    /// without editing the machine's Language & Region settings.
    nonisolated static func firstPreferred(in tracks: [MediaTrack],
                                           matching preference: TrackLanguagePreference)
        -> MediaTrack? {
        // impl: PREF-001 rule 3 — an unset list is the system's, not "none".
        let languages = preference.languages.isEmpty
            ? LanguageCode.systemPreferred()
            : preference.languages

        for language in languages {
            let candidates = tracks.filter { alpha2($0.language) == language }
            guard let first = candidates.first else { continue }
            if let tieBreak = candidates.first(where: { $0.matches(nameFilter: preference.nameFilter) }) {
                return tieBreak
            }
            return first
        }
        return nil
    }

    /// impl: PREF-001 rule 2 — ISO 639-2/B, the *bibliographic* codes.
    ///
    /// Twenty languages have two three-letter spellings, and Matroska routinely
    /// uses the bibliographic one while Foundation only understands the
    /// terminological one. Without this table `fre` mapped to nothing, so a
    /// French track never matched `fr` and fell to TRACK-001 rule 8's "otherwise
    /// Off" — while Japanese, which has no such pair, matched perfectly on the
    /// same file. That selectivity is what makes the bug read as "the setting
    /// does nothing" instead of as a code-mapping fault.
    nonisolated private static let bibliographicToTerminological = [
        "alb": "sqi", "arm": "hye", "baq": "eus", "bur": "mya", "chi": "zho",
        "cze": "ces", "dut": "nld", "fre": "fra", "geo": "kat", "ger": "deu",
        "gre": "ell", "ice": "isl", "mac": "mkd", "mao": "mri", "may": "msa",
        "per": "fas", "rum": "ron", "slo": "slk", "tib": "bod", "wel": "cym",
    ]

    /// libvlc reports ISO 639-2 (`eng`); `Locale.preferredLanguages` is 639-1
    /// (`en`). Comparing them without this conversion never matches.
    nonisolated static func alpha2(_ code: String?) -> String? {
        guard let code, !code.isEmpty, code != "und" else { return nil }
        if code.count == 2 { return code.lowercased() }
        let lowered = code.lowercased()
        let normalised = bibliographicToTerminological[lowered] ?? lowered
        return Locale.LanguageCode(normalised).identifier(.alpha2)
    }
}
