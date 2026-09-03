// impl: PREF-001 rules 9-13, 19-20 — where the preference lives between runs.
//
// Reading is tolerant and *reports* what it rejected (rule 10), on the model of
// `VolumeController.restore()`: a corrupt value falls back to something usable
// and says so, rather than leaving the app in a state nobody chose.

import Foundation

@MainActor
final class TrackPreferencesStore {
    private let defaults: UserDefaults

    private(set) var audio: TrackLanguagePreference = .unset
    private(set) var subtitle: TrackLanguagePreference = .unset

    /// impl: PREF-001 rule 12 — set by AppDelegate to re-run the owning
    /// controller's `applyDefault()`. Carries the kind so only the affected
    /// track list is reconsidered.
    var onChange: ((TrackKind) -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        restore()
    }

    func preference(for kind: TrackKind) -> TrackLanguagePreference {
        switch kind {
        case .audio: audio
        case .subtitle: subtitle
        }
    }

    // MARK: - Restore

    /// impl: PREF-001 rules 10, 20 — one entry at launch saying what was read
    /// and where from. Without it a test cannot tell "the preference was
    /// applied" from "the preference was never read".
    private func restore() {
        let audioResult = read(.audio)
        let subtitleResult = read(.subtitle)
        audio = audioResult.preference
        subtitle = subtitleResult.preference

        // impl: PREF-001 rule 20 — `source` names where the *effective* order
        // came from. With both lists empty the answer is the system list (rule
        // 3), whether that is because nothing was ever set or because a value
        // was explicitly cleared; "arguments" would be true of the key and false
        // of the order it produced.
        let source: String
        if audio.languages.isEmpty, subtitle.languages.isEmpty {
            source = "systemFallback"
        } else if audioResult.fromArguments || subtitleResult.fromArguments {
            source = "arguments"
        } else {
            source = "stored"
        }

        log(.preferencesRestored, .info, [
            "audioLanguages": audio.languages,
            "audioFilter": audio.nameFilter,
            "subtitleLanguages": subtitle.languages,
            "subtitleFilter": subtitle.nameFilter,
            "systemFallback": LanguageCode.systemPreferred(),
            "source": source,
        ])
    }

    private func read(_ kind: TrackKind) -> (preference: TrackLanguagePreference,
                                             fromArguments: Bool) {
        let languagesKey = "\(kind.defaultsPrefix).languages"
        let filterKey = "\(kind.defaultsPrefix).nameFilter"

        let stored = defaults.object(forKey: languagesKey)
        let parsed = LanguageCode.parse(stored)
        // impl: PREF-001 rule 10 — every rejected entry is named, not swallowed.
        if !parsed.rejected.isEmpty {
            log(.preferencesLanguageRejected, .warn, [
                "kind": kind.rawValue,
                "rejected": parsed.rejected,
                "reason": "notATwoLetterCode",
            ])
        }
        // A value that was present but left nothing usable falls back to the
        // system list (rule 10's last sentence), which is what an empty
        // `languages` array means downstream (rule 3).
        //
        // Only when something was actually *rejected*: an explicitly empty value
        // is "no preference" (rule 3), not corruption, and warning about it
        // would make clearing the list look like a fault.
        if stored != nil, parsed.codes.isEmpty, !parsed.rejected.isEmpty {
            log(.preferencesRestored, .warn, [
                "kind": kind.rawValue,
                "reason": "storedValueUnusable",
                "fallback": "system",
            ])
        }

        let filter = (defaults.object(forKey: filterKey) as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // `NSArgumentDomain` is where `-key value` launch arguments land, and it
        // is the only domain a test writes. Distinguishing it is what lets
        // PREF-001-H1 assert the preference arrived from the harness.
        let fromArguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)[languagesKey] != nil

        return (TrackLanguagePreference(languages: parsed.codes, nameFilter: filter), fromArguments)
    }

    // MARK: - Update

    /// impl: PREF-001 rules 11-12 — written immediately, then applied. There is
    /// no Save button: a settings window with a modal commit is a second source
    /// of truth.
    func update(_ preference: TrackLanguagePreference, for kind: TrackKind) {
        guard preference != self.preference(for: kind) else { return }
        switch kind {
        case .audio: audio = preference
        case .subtitle: subtitle = preference
        }
        defaults.set(preference.languages, forKey: "\(kind.defaultsPrefix).languages")
        defaults.set(preference.nameFilter, forKey: "\(kind.defaultsPrefix).nameFilter")

        log(.preferencesChanged, .info, [
            "kind": kind.rawValue,
            "languages": preference.languages,
            "filter": preference.nameFilter,
        ])
        onChange?(kind)
    }
}
