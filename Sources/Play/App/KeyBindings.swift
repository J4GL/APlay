// impl: CTRL-002 rules 1, 5, 9 — one table, one switch.
//
// Rule 1 is enforced literally: a row exists here only when its action is
// implemented, and every row in the rule-1 table now is.

import AppKit

/// impl: CTRL-002 rule 5 — the closed set of things a key can ask for.
enum PlayerAction: String, Sendable {
    case togglePlayPause
    case seekBackward5, seekForward5, seekBackward60, seekForward60
    case volumeUp, volumeDown, toggleMute
    case toggleFullscreen, exitFullscreen
    case cycleSubtitleTrack, cycleAudioTrack
    case subtitleDelayEarlier, subtitleDelayLater
    case subtitleDelayEarlierLarge, subtitleDelayLaterLarge, subtitleDelayReset
    case nextItem, previousItem, toggleQueuePanel, removeQueueRow
    /// impl: CTRL-004 rule 4 — a menu-only action: LIST-001 rule 11's shuffle
    /// has always been button-only, and gains no key equivalent here.
    case toggleShuffle
    case openDocument, closeMedia, openSettings, minimise, closeWindow, quit

    /// impl: CTRL-002 rule 9 — repeat is honoured for continuous actions and
    /// suppressed for every toggle. Holding Space must not flap play/pause.
    var honoursKeyRepeat: Bool {
        switch self {
        case .seekBackward5, .seekForward5, .seekBackward60, .seekForward60,
             .volumeUp, .volumeDown,
             .subtitleDelayEarlier, .subtitleDelayLater,
             .subtitleDelayEarlierLarge, .subtitleDelayLaterLarge:
            true
        default:
            false
        }
    }
}

enum KeyBindings {
    /// impl: CTRL-002 rule 1 — the binding table. `nil` means "not ours";
    /// rule 8 requires such events to reach `super` unlogged.
    static func action(for event: NSEvent) -> PlayerAction? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = flags.contains(.command)
        let shift = flags.contains(.shift)

        if command {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "o": return .openDocument
            case ".": return .closeMedia
            case ",": return .openSettings
            case "l": return .toggleQueuePanel
            case "]": return .nextItem
            case "[": return .previousItem
            case "m": return .minimise
            case "w": return .closeWindow
            case "q": return .quit
            default: return nil
            }
        }

        switch Int(event.keyCode) {
        case 49: return .togglePlayPause                                  // Space
        case 123: return shift ? .seekBackward60 : .seekBackward5         // ←
        case 124: return shift ? .seekForward60 : .seekForward5           // →
        case 126: return .volumeUp                                        // ↑
        case 125: return .volumeDown                                      // ↓
        case 53: return .exitFullscreen                                   // Esc
        case 51: return .removeQueueRow                                   // ⌫
        default: break
        }

        // impl: CTRL-002 rule 4 — bare letters are used freely because Play has
        // no text entry anywhere. `⌥H` is the one modified letter row.
        let option = flags.contains(.option)
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "m" where !option: return .toggleMute
        case "f" where !option: return .toggleFullscreen
        case "s" where !option: return .cycleSubtitleTrack
        case "a" where !option: return .cycleAudioTrack
        case "h":
            if option { return .subtitleDelayReset }
            return shift ? .subtitleDelayEarlierLarge : .subtitleDelayEarlier
        case "j" where !option:
            return shift ? .subtitleDelayLaterLarge : .subtitleDelayLater
        default: return nil
        }
    }

    /// impl: TRACK-002 rule 1 — the two delay magnitudes, in one place.
    static func subtitleDelayStepMs(for action: PlayerAction) -> Int? {
        switch action {
        case .subtitleDelayEarlier: -100
        case .subtitleDelayLater: 100
        case .subtitleDelayEarlierLarge: -1_000
        case .subtitleDelayLaterLarge: 1_000
        default: nil
        }
    }

    /// impl: PLAY-002 rule 9 — the two seek magnitudes, in one place.
    static func seekDeltaMs(for action: PlayerAction) -> Int? {
        switch action {
        case .seekBackward5: -5_000
        case .seekForward5: 5_000
        case .seekBackward60: -60_000
        case .seekForward60: 60_000
        default: nil
        }
    }
}
