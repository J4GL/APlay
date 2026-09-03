// impl: LOG-001 rules 3-4 — the closed vocabulary of event names.
//
// The logging API takes this enum, not a String, so a test asserting on an
// event name can never silently drift from the emitter.

import Foundation

public enum LogLevel: String, Sendable, Comparable {
    case trace, debug, info, warn, error

    private var rank: Int {
        switch self {
        case .trace: 0; case .debug: 1; case .info: 2; case .warn: 3; case .error: 4
        }
    }
    public static func < (a: LogLevel, b: LogLevel) -> Bool { a.rank < b.rank }
}

public enum LogEvent: String, Sendable {
    // app
    case appLaunchOk          = "app.launch.ok"
    case appTerminateOk       = "app.terminate.ok"
    case appLogPruned         = "app.log.pruned"

    // platform / VLC-001
    case bootstrapOk          = "platform.bootstrap.ok"
    case bootstrapFailed      = "platform.bootstrap.failed"
    case bootstrapSlow        = "platform.bootstrap.slow"

    // engine / VLC-002
    case enginePlayerCreated  = "engine.player.created"
    case engineMediaSet       = "engine.media.set"
    case engineStateChanged   = "engine.state.changed"
    case engineCallbacksAttached = "engine.callbacks.attached"
    case engineCallbacksDetached = "engine.callbacks.detached"
    case enginePlayerReleased = "engine.player.released"
    case engineError          = "engine.error"
    case engineVout           = "engine.vout"

    // window / WIN-001..003
    case windowCreated        = "window.created"
    case windowMoved          = "window.moved"
    case windowResized        = "window.resized"
    case windowClosed         = "window.closed"
    case windowBecameKey      = "window.becameKey"
    case windowResignedKey    = "window.resignedKey"
    case windowSizedToVideo   = "window.sizedToVideo"
    case windowAspectRatioSuspended = "window.aspectRatio.suspended"
    case windowAspectRatioRestored  = "window.aspectRatio.restored"
    case windowAspectRatioUnavailable = "window.aspectRatio.unavailable"
    case windowGeometrySaved     = "window.geometry.saved"
    case windowGeometryRestored  = "window.geometry.restored"
    case windowGeometryDiscarded = "window.geometry.discarded"
    case windowCloseClicked   = "window.close.clicked"
    case windowFullscreenEnter = "window.fullscreen.enter"
    case windowFullscreenExit  = "window.fullscreen.exit"
    case windowFullscreenRestored = "window.fullscreen.restored"

    // media / MEDIA-001..002
    case mediaOpenRequested   = "media.open.requested"
    case mediaOpenOk          = "media.open.ok"
    case mediaOpenFailed      = "media.open.failed"
    case mediaOpenCancelled   = "media.open.cancelled"
    case mediaOpenRejectedDrag = "media.open.rejectedDrag"
    case mediaDragEntered     = "media.drag.entered"
    case mediaDragExited      = "media.drag.exited"
    case mediaBannerShown     = "media.banner.shown"
    case mediaBannerDismissed = "media.banner.dismissed"

    // playback / PLAY-001..003
    case playbackStateChanged = "playback.state.changed"
    case playbackStateIllegal = "playback.state.illegal"
    case playbackTransportPlay   = "playback.transport.play"
    case playbackTransportPause  = "playback.transport.pause"
    case playbackTransportToggle = "playback.transport.toggle"
    case playbackTransportStop   = "playback.transport.stop"
    case playbackTransportIgnored = "playback.transport.ignored"
    case playbackEnded        = "playback.ended"
    case playbackSleepPrevented = "playback.sleep.prevented"
    case playbackSleepReleased  = "playback.sleep.released"
    case playbackSeekClick    = "playback.seek.click"
    case playbackSeekKeyboard = "playback.seek.keyboard"
    case playbackSeekScrub    = "playback.seek.scrub"
    case playbackSeekScrubPause = "playback.seek.scrubPause"
    case playbackSeekRejected = "playback.seek.rejected"
    case playbackVolumeChanged = "playback.volume.changed"
    case playbackMuteChanged   = "playback.mute.changed"

    // resume / PLAY-004
    case playbackResumeSaved     = "playback.resume.saved"
    case playbackResumeOffered   = "playback.resume.offered"
    case playbackResumeAccepted  = "playback.resume.accepted"
    case playbackResumeDismissed = "playback.resume.dismissed"
    case playbackResumeSkipped   = "playback.resume.skipped"
    case playbackResumeCleared   = "playback.resume.cleared"
    case playbackResumeStoreReset = "playback.resume.storeReset"

    // tracks / TRACK-001 rule 15
    case tracksSubtitleListChanged    = "tracks.subtitle.listChanged"
    case tracksSubtitleSelected       = "tracks.subtitle.selected"
    case tracksSubtitleCycled         = "tracks.subtitle.cycled"
    case tracksSubtitleExternalAdded  = "tracks.subtitle.externalAdded"
    case tracksSubtitleExternalFailed = "tracks.subtitle.externalFailed"
    case tracksSubtitleSidecarsFound  = "tracks.subtitle.sidecarsFound"

    // tracks / TRACK-003 rule 10
    case tracksAudioListChanged       = "tracks.audio.listChanged"
    case tracksAudioSelected          = "tracks.audio.selected"
    case tracksAudioCycled            = "tracks.audio.cycled"
    case tracksAudioDisabled          = "tracks.audio.disabled"

    // tracks / TRACK-002 rule 8
    case tracksDelayChanged           = "tracks.delay.changed"
    case tracksDelayReset             = "tracks.delay.reset"
    case tracksDelayClamped           = "tracks.delay.clamped"
    case tracksDelayIgnored           = "tracks.delay.ignored"

    // playlist / LIST-001 rule 13
    case playlistBuilt                = "playlist.built"
    case playlistAppended             = "playlist.appended"
    case playlistAdvanced             = "playlist.advanced"
    case playlistRestartedCurrent     = "playlist.restartedCurrent"
    case playlistItemFailed           = "playlist.itemFailed"
    case playlistAdvanceIgnored       = "playlist.advance.ignored"
    case playlistShuffled             = "playlist.shuffled"
    case playlistExhausted            = "playlist.exhausted"

    // playlist / LIST-002 rule 13
    case playlistPanelOpened          = "playlist.panel.opened"
    case playlistPanelClosed          = "playlist.panel.closed"
    case playlistRowClicked           = "playlist.row.clicked"
    case playlistReordered            = "playlist.reordered"
    case playlistRemoved              = "playlist.removed"
    case playlistReorderRejected      = "playlist.reorderRejected"

    // hud / CTRL-001
    case hudShown             = "hud.shown"
    case hudHidden            = "hud.hidden"
    case hudAutoHideSuppressed = "hud.autoHide.suppressed"
    case hudControlPressed    = "hud.control.pressed"
    case hudLayoutCompact     = "hud.layout.compact"

    // input / CTRL-002
    case inputKey             = "input.key"

    // window / WIN-001 rule 16
    case windowDragRefused    = "window.drag.refused"

    // menu / CTRL-004 rule 15
    case menuOpened           = "menu.opened"
    case menuClosed           = "menu.closed"

    // preferences / PREF-001 rules 19-20
    case preferencesRestored          = "preferences.restored"
    case preferencesChanged           = "preferences.changed"
    case preferencesWindowOpened      = "preferences.window.opened"
    case preferencesWindowClosed      = "preferences.window.closed"
    case preferencesLanguageAdded     = "preferences.language.added"
    case preferencesLanguageRemoved   = "preferences.language.removed"
    case preferencesLanguageMoved     = "preferences.language.moved"
    case preferencesLanguageRejected  = "preferences.language.rejected"
    case preferencesFilterChanged     = "preferences.filter.changed"

    // vlc's own log, bridged
    case vlcLog               = "vlc.log"
}

public extension LogEvent {
    /// impl: LOG-001 rule 3 — subsystem is derived from the name, so the two
    /// can never disagree.
    var subsystem: String { String(rawValue.prefix(while: { $0 != "." })) }
}
