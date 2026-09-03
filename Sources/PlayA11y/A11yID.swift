// impl: CTRL-003 rules 1-3 — the accessibility identifier registry.
//
// In its own module so the UI test bundle can import it: a UI test target
// cannot `@testable import` the app under test, so a shared module is the only
// way to keep one source of truth. A rename here is a compile error in both the
// app and the tests, rather than a silently failing query.

import Foundation

public enum A11yID: String, CaseIterable, Sendable {
    // window
    case windowContentRoot        = "play.window.contentRoot"
    case windowVideoView          = "play.window.videoView"
    case windowEmptyStateHint     = "play.window.emptyStateHint"
    case windowDropHighlight      = "play.window.dropHighlight"

    // hud
    case hudRoot                  = "play.hud.root"
    case hudPlayPauseButton       = "play.hud.playPauseButton"
    case hudSeekBar               = "play.hud.seekBar"
    case hudSeekBarKnob           = "play.hud.seekBarKnob"
    case hudSeekPreview           = "play.hud.seekPreview"
    case hudElapsedTime           = "play.hud.elapsedTime"
    case hudRemainingTime         = "play.hud.remainingTime"
    case hudVolumeSlider          = "play.hud.volumeSlider"
    case hudMuteButton            = "play.hud.muteButton"
    case hudSubtitleMenuButton    = "play.hud.subtitleMenuButton"
    case hudAudioMenuButton       = "play.hud.audioMenuButton"
    case hudQueueButton           = "play.hud.queueButton"
    case hudShuffleButton         = "play.hud.shuffleButton"
    case hudPreviousButton        = "play.hud.previousButton"
    case hudNextButton            = "play.hud.nextButton"
    case hudFullscreenButton      = "play.hud.fullscreenButton"
    case hudCloseButton           = "play.hud.closeButton"
    case hudOverflowButton        = "play.hud.overflowButton"

    // menus — the HUD popups
    case menuSubtitleTracks       = "play.menu.subtitleTracks"
    case menuAudioTracks          = "play.menu.audioTracks"

    // menus — the menu bar (CTRL-004 rule 1)
    case menuFile                 = "play.menu.file"
    case menuPlayback             = "play.menu.playback"
    case menuAudio                = "play.menu.audio"
    case menuSubtitle             = "play.menu.subtitle"
    case menuWindow               = "play.menu.window"

    // preferences (PREF-001 rules 14-16)
    case preferencesWindow            = "play.preferences.window"
    case preferencesAudioLanguages    = "play.preferences.audioLanguages"
    case preferencesAudioNameFilter   = "play.preferences.audioNameFilter"
    case preferencesAudioAdd          = "play.preferences.audioAddLanguage"
    case preferencesAudioRemove       = "play.preferences.audioRemoveLanguage"
    case preferencesSubtitleLanguages = "play.preferences.subtitleLanguages"
    case preferencesSubtitleNameFilter = "play.preferences.subtitleNameFilter"
    case preferencesSubtitleAdd       = "play.preferences.subtitleAddLanguage"
    case preferencesSubtitleRemove    = "play.preferences.subtitleRemoveLanguage"

    // queue
    case queuePanel               = "play.queue.panel"

    // transient surfaces
    case toastResume              = "play.toast.resume"
    case toastResumeAction        = "play.toast.resume.action"
    case toastResumeDismiss       = "play.toast.resume.dismiss"
    case bannerMediaFailure       = "play.banner.mediaFailure"
    case bannerMediaFailureDismiss = "play.banner.mediaFailure.dismiss"
    case alertBootstrapFailure    = "play.alert.bootstrapFailure"
    case overlaySubtitleDelay     = "play.overlay.subtitleDelayReadout"

    /// impl: CTRL-003 rule 4 — indexed by *current* visible position, so a query
    /// for row 2 always addresses what the user sees at position 2.
    public static func queueRow(_ index: Int) -> String { "play.queue.row.\(index)" }

    /// impl: LIST-002 rule 10 — the hover `✕` on a row, addressed by the same
    /// current-position index as the row itself.
    public static func queueRowRemove(_ index: Int) -> String { "play.queue.row.\(index).remove" }

    /// impl: CTRL-004 rule 1 / CTRL-003 rule 11 — one menu item, named by the
    /// `PlayerAction` it performs. Addressing items by visible title breaks on
    /// the first localisation and cannot tell apart two items that legitimately
    /// read the same, such as "Close Window" in both File and Window.
    public static func menuItem(_ action: String) -> String { "play.menu.item.\(action)" }

    /// impl: CTRL-003 rule 4 / PREF-001 rule 15 — one language row, by kind and
    /// **current** position. The order *is* the preference, so an identifier
    /// holding a stale index would make the reordering assertion prove nothing.
    public static func preferencesLanguageRow(_ kind: String, _ index: Int) -> String {
        "play.preferences.languageRow.\(kind).\(index)"
    }
}
