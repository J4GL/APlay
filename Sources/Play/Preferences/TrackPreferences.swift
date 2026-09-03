// impl: PREF-001 rules 1-5, 8, 10 — which language you want, and which of two
// same-language tracks.
//
// Everything here is pure and `nonisolated`: no libvlc, no UserDefaults, no
// window. That is what rule 8 is for — TRACK-003-H2 asked for "the system's
// preferred language set to French" and was unimplementable for as long as the
// answer came from the machine's own settings.

import Foundation

/// impl: PREF-001 rule 1 — audio and subtitles are never merged.
enum TrackKind: String, Sendable, CaseIterable {
    case audio, subtitle

    /// impl: PREF-001 rule 9 — the stored key prefix, matching the dotted
    /// convention `VolumeController` established (`audio.volume`).
    var defaultsPrefix: String {
        switch self {
        case .audio: "tracks.audio"
        case .subtitle: "tracks.subtitle"
        }
    }
}

/// impl: PREF-001 rules 1-2 — an ordered list of two-letter codes, plus one
/// tie-breaker.
struct TrackLanguagePreference: Equatable, Sendable {
    /// ISO 639-1, lowercase, in the user's order. Empty means "use the system
    /// list" (rule 3) — it is not the same thing as "prefer nothing".
    var languages: [String] = []
    /// Empty means no tie-breaker (rule 5).
    var nameFilter: String = ""

    static let unset = TrackLanguagePreference()
}

/// impl: PREF-001 rules 2, 10 — parsing and validating two-letter codes.
enum LanguageCode {
    /// impl: PREF-001 rule 2 — the only shape accepted anywhere: exactly two
    /// ASCII letters, stored lowercase.
    nonisolated static func normalised(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.count == 2,
              trimmed.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
        return trimmed
    }

    /// impl: PREF-001 rule 3 — the fallback list, in the system's own order.
    nonisolated static func systemPreferred() -> [String] {
        var seen: Set<String> = []
        return Locale.preferredLanguages.compactMap {
            Locale(identifier: $0).language.languageCode?.identifier(.alpha2)
        }.compactMap(normalised).filter { seen.insert($0).inserted }
    }

    /// impl: PREF-001 rule 10 — a stored value is accepted as an array of
    /// strings *or* as one comma-separated string, so a test can inject it
    /// through `launchArguments` into `NSArgumentDomain`. Entries are trimmed,
    /// lowercased and de-duplicated keeping first position; anything that is not
    /// a two-letter code is reported rather than silently dropped.
    nonisolated static func parse(_ stored: Any?) -> (codes: [String], rejected: [String]) {
        let pieces: [String]
        switch stored {
        case let list as [String]:
            pieces = list
        case let text as String:
            pieces = text.split(separator: ",").map(String.init)
        case let list as [Any]:
            pieces = list.map { String(describing: $0) }
        default:
            return ([], [])
        }

        var codes: [String] = []
        var rejected: [String] = []
        var seen: Set<String> = []
        for piece in pieces {
            let candidate = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !candidate.isEmpty else { continue }
            guard let code = normalised(candidate) else {
                rejected.append(candidate)
                continue
            }
            if seen.insert(code).inserted { codes.append(code) }
        }
        return (codes, rejected)
    }

    /// impl: PREF-001 rule 15 — a row reads `fr — French`, so the code being
    /// stored is never a mystery. Falls back to the bare code when the system
    /// has no name for it.
    nonisolated static func rowTitle(for code: String) -> String {
        guard let name = TrackCatalog.localizedLanguage(code) else { return code }
        return "\(code) — \(name)"
    }

    /// The `+` control's list: every two-letter code the system can name,
    /// ordered by the name a person reads rather than by the code.
    nonisolated static func selectable() -> [String] {
        var seen: Set<String> = []
        let codes = Locale.LanguageCode.isoLanguageCodes
            .compactMap { $0.identifier(.alpha2) }
            .compactMap(normalised)
            .filter { seen.insert($0).inserted }
            .filter { TrackCatalog.localizedLanguage($0) != nil }
        return codes.sorted {
            (TrackCatalog.localizedLanguage($0) ?? $0)
                .localizedCaseInsensitiveCompare(TrackCatalog.localizedLanguage($1) ?? $1)
                == .orderedAscending
        }
    }
}
