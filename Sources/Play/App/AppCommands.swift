// impl: CTRL-002 rules 5-7, 10-11 · MEDIA-001 rule 1 — the one switch over
// PlayerAction.
//
// Adding a binding means adding a row in KeyBindings and a case here. Nothing
// dispatches keys anywhere else.

import AppKit
import PlayA11y

@MainActor
final class AppCommands {
    private let opener: FileOpener
    private let transport: TransportController
    private let seeker: SeekController
    private let volume: VolumeController
    private let fullscreen: FullscreenController
    private let subtitles: SubtitleController
    private let audioTracks: AudioTrackController
    private let subtitleDelay: SubtitleDelayController
    private let advancer: QueueAdvancer
    private let state: PlaybackState
    /// impl: PREF-001 rule 14 — the one window this switch can open.
    private let preferences: PreferencesWindowController
    private unowned let window: NSWindow

    /// impl: CTRL-002 rule 7 — any handled press reveals the HUD, so
    /// keyboard-only use still shows its feedback.
    var onActivity: ((HUDShowTrigger) -> Void)?

    /// impl: LIST-002 rule 2 — set by AppDelegate once the panel exists (it is
    /// built with the HUD, after this object). Weak: the content root owns it.
    weak var queuePanel: QueueOverlayView?

    /// impl: CTRL-004 rule 6 / LIST-001 rule 11 — set by AppDelegate to
    /// `HUDView.toggleShuffle`, which owns the on/off state. Returns the new
    /// state so `MainMenu` can show its check mark without a second copy.
    var onToggleShuffle: (() -> Bool)?

    /// impl: CTRL-004 rule 6 — read by `MainMenu.validateMenuItem`.
    var isShuffled: (() -> Bool)?

    init(opener: FileOpener,
         transport: TransportController,
         seeker: SeekController,
         volume: VolumeController,
         fullscreen: FullscreenController,
         subtitles: SubtitleController,
         audioTracks: AudioTrackController,
         subtitleDelay: SubtitleDelayController,
         advancer: QueueAdvancer,
         state: PlaybackState,
         preferences: PreferencesWindowController,
         window: NSWindow) {
        self.opener = opener
        self.transport = transport
        self.seeker = seeker
        self.volume = volume
        self.fullscreen = fullscreen
        self.subtitles = subtitles
        self.audioTracks = audioTracks
        self.subtitleDelay = subtitleDelay
        self.advancer = advancer
        self.state = state
        self.preferences = preferences
        self.window = window
    }

    // MARK: - Key entry point

    /// impl: CTRL-002 rules 8-9, 11 — returns false for anything not ours, so
    /// `BorderlessWindow` can pass it to `super` unlogged.
    @discardableResult
    func handle(_ event: NSEvent) -> Bool {
        guard let action = KeyBindings.action(for: event) else { return false }
        // impl: CTRL-002 rule 9
        if event.isARepeat, !action.honoursKeyRepeat { return true }

        let accepted = perform(action, element: "key")
        logInput(action, accepted: accepted, source: "keyboard",
                 key: event.charactersIgnoringModifiers ?? "",
                 modifiers: modifierNames(event))
        if accepted { onActivity?(.key) }
        return true
    }

    /// impl: CTRL-004 rules 6-7 — the menu's only entry point.
    ///
    /// AppKit matches a menu's key equivalents in `sendEvent`, *before* the
    /// event reaches `BorderlessWindow.keyDown`. So from the moment a menu bar
    /// exists, every ⌘ binding arrives here instead of through `handle(_:)`.
    /// Emitting the same `input.key` event — with `source` saying which route it
    /// took — is what stops that reroute from silently erasing CTRL-002 rule
    /// 11's trace, which is the whole basis of the keyboard assertions in the
    /// suite. Called only by `MainMenu`.
    @discardableResult
    func performFromMenu(_ action: PlayerAction) -> Bool {
        // A menu item fires from a click *or* from its key equivalent, and the
        // log must not claim the user reached for the mouse when they did not.
        // This is decided **before** the action runs, because `element` carries
        // the same answer into every log the action produces — CTRL-004 rule 7,
        // second paragraph. Passing a flat "menu" is what made LIST-002-H1 read
        // `playlist.panel.opened {trigger: "menu"}` for a ⌘L.
        let event = NSApp.currentEvent
        let viaKey = event?.type == .keyDown
        let accepted = perform(action, element: viaKey ? "keyEquivalent" : "menu")
        logInput(action, accepted: accepted,
                 source: viaKey ? "keyEquivalent" : "menu",
                 key: viaKey ? (event?.charactersIgnoringModifiers ?? "") : "",
                 modifiers: viaKey ? modifierNames(event!) : [])
        // impl: CTRL-004 rule 14 — the pointer never touched the video, so the
        // effect of the command still has to be made visible.
        if accepted { onActivity?(.menu) }
        return accepted
    }

    /// impl: CTRL-002 rule 11 — one event name for every route into the switch.
    private func logInput(_ action: PlayerAction,
                          accepted: Bool,
                          source: String,
                          key: String,
                          modifiers: [String]) {
        log(.inputKey, .info, [
            "key": key,
            "modifiers": modifiers,
            "action": action.rawValue,
            "accepted": accepted,
            "source": source,
        ])
    }

    private func modifierNames(_ event: NSEvent) -> [String] {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var names: [String] = []
        if flags.contains(.command) { names.append("command") }
        if flags.contains(.shift) { names.append("shift") }
        if flags.contains(.option) { names.append("option") }
        if flags.contains(.control) { names.append("control") }
        return names
    }

    // MARK: - The one switch

    /// impl: CTRL-002 rules 5, 10 — an action whose precondition fails is
    /// refused and reported, never attempted.
    @discardableResult
    func perform(_ action: PlayerAction, element: String) -> Bool {
        switch action {
        case .togglePlayPause:
            transport.toggle(element: element)
            return true

        case .seekBackward5, .seekForward5, .seekBackward60, .seekForward60:
            guard let delta = KeyBindings.seekDeltaMs(for: action) else { return false }
            seeker.nudge(byMs: delta, element: element)
            return true

        case .volumeUp:
            volume.adjust(byPercent: 5, source: "keyboard", element: element)
            return true
        case .volumeDown:
            volume.adjust(byPercent: -5, source: "keyboard", element: element)
            return true
        case .toggleMute:
            volume.toggleMute(element: element)
            return true

        case .toggleFullscreen:
            fullscreen.toggle(element: element)
            return true
        case .exitFullscreen:
            // impl: CTRL-002 rule 2 — Esc is ordered: fullscreen first, then the
            // queue panel, then nothing. It never quits and never closes media.
            if fullscreen.isFullscreen {
                fullscreen.exit(element: element)
                return true
            }
            return queuePanel?.close(trigger: .escape) ?? false

        // impl: TRACK-001 rule 7 — `S` cycles subtitles, wrapping through Off.
        // Rule 10: with no subtitle track at all there is nothing to cycle, so
        // it is refused with a reason rather than attempted.
        case .cycleSubtitleTrack:
            guard !subtitles.tracks.isEmpty else { return false }
            subtitles.cycle()
            return true

        // impl: TRACK-003 rule 7 — `A` cycles audio tracks.
        case .cycleAudioTrack:
            guard !audioTracks.tracks.isEmpty else { return false }
            audioTracks.cycle()
            return true

        // impl: TRACK-002 rules 1, 6 — H/J and ⇧H/⇧J; refused with a logged
        // reason when no subtitle track is showing.
        case .subtitleDelayEarlier, .subtitleDelayLater,
             .subtitleDelayEarlierLarge, .subtitleDelayLaterLarge:
            guard let step = KeyBindings.subtitleDelayStepMs(for: action) else { return false }
            guard subtitles.selectedID != nil else {
                subtitleDelay.step(byMs: step, element: element)   // logs .ignored
                return false
            }
            subtitleDelay.step(byMs: step, element: element)
            return true

        case .subtitleDelayReset:
            guard subtitles.selectedID != nil else {
                subtitleDelay.reset(element: element)              // logs .ignored
                return false
            }
            subtitleDelay.reset(element: element)
            return true

        // impl: LIST-001 rules 6-7 — ⌘] / ⌘[. Both report their own refusal
        // (`playlist.advance.ignored`) rather than being pre-guarded here, so
        // the log says *why* nothing happened even on an empty queue.
        case .nextItem:
            return advancer.next()

        case .previousItem:
            return advancer.previousOrRestart(element: element)

        // impl: LIST-002 rules 2-3 — ⌘L. A one-item queue has no panel at all,
        // so the key is refused rather than opening an empty one.
        case .toggleQueuePanel:
            // impl: LIST-002 rule 13 / CTRL-004 rule 7 — a ⌘L the Window menu
            // matched is still the keyboard; `menu` means the item was clicked.
            let trigger: PanelTrigger = switch element {
            case "key", "keyEquivalent": .keyboard
            case "menu": .menu
            default: .button
            }
            return queuePanel?.toggle(trigger: trigger) ?? false

        // impl: CTRL-004 rule 6 / LIST-001 rule 11 — the HUD owns the shuffle
        // state; the menu asks it to toggle rather than keeping a second copy.
        case .toggleShuffle:
            guard let onToggleShuffle, advancer.hasQueue else { return false }
            onToggleShuffle()
            return true

        // impl: LIST-002 rule 10 — ⌫ removes the selected row, and means
        // nothing anywhere else.
        case .removeQueueRow:
            return queuePanel?.removeSelectedRow() ?? false

        case .openDocument:
            openDocument()
            return true

        // impl: PREF-001 rule 14 — ⌘, and CTRL-004's Settings… item are the only
        // two routes to the window, and they land on the same call.
        case .openSettings:
            return preferences.show(trigger: element)

        case .closeMedia:
            // impl: PLAY-001 rule 7 — the only route to stop().
            guard state.status != .idle else { return false }
            transport.stop(element: element)
            return true

        // impl: WIN-001 rules 1, 11 — `performMiniaturize`/`performClose`
        // simulate a click on a titlebar button, and a borderless window has
        // none, so both are silent no-ops here however the style mask reads.
        // These two act directly.
        case .minimise:
            window.miniaturize(nil)
            return true
        case .closeWindow:
            window.close()
            return true
        case .quit:
            NSApp.terminate(nil)
            return true
        }
    }

    // MARK: - Validation

    /// impl: CTRL-004 rule 8 — the same preconditions the switch above enforces,
    /// asked without performing anything, so a menu item can be greyed instead
    /// of clicked into a logged refusal. Greying is observable feedback in its
    /// own right (AGENTS.md rule 6).
    ///
    /// impl: CTRL-004 rule 9 — a *disabled* item must leave its key equivalent
    /// to the responder chain, so `⌘]` in the empty state still reaches
    /// `BorderlessWindow.keyDown` and logs `accepted: false`. That keeps
    /// CTRL-002-S2 true, and CTRL-004-S1 measures it.
    func canPerform(_ action: PlayerAction) -> Bool {
        switch action {
        case .togglePlayPause:
            // PLAY-001 rule 5 — the toggle is ignored while idle, failed or
            // still opening; those are the states with nothing to toggle.
            return switch state.status {
            case .playing, .paused, .ended: true
            default: false
            }

        case .seekBackward5, .seekForward5, .seekBackward60, .seekForward60:
            // `failed` carries its reason, so it cannot be compared with `!=`.
            return switch state.status {
            case .idle, .failed: false
            default: true
            }

        // PLAY-003 — volume is Play's own, and works with no media loaded.
        case .volumeUp, .volumeDown, .toggleMute:
            return true

        case .toggleFullscreen, .exitFullscreen:
            return true

        case .cycleSubtitleTrack:
            return !subtitles.tracks.isEmpty
        case .cycleAudioTrack:
            return !audioTracks.tracks.isEmpty

        // TRACK-002 rule 6 — a delay with no subtitle showing means nothing.
        case .subtitleDelayEarlier, .subtitleDelayLater,
             .subtitleDelayEarlierLarge, .subtitleDelayLaterLarge, .subtitleDelayReset:
            return subtitles.selectedID != nil

        case .nextItem:
            return advancer.canGoNext
        case .previousItem:
            return advancer.canGoPrevious
        // LIST-002 rule 3 / LIST-001 rule 11 — a one-item queue has no panel and
        // nothing to shuffle.
        case .toggleQueuePanel, .toggleShuffle:
            return advancer.hasQueue
        case .removeQueueRow:
            return queuePanel?.isOpen == true && queuePanel?.selectedIndex != nil

        case .closeMedia:
            return state.status != .idle

        case .openDocument, .openSettings, .minimise, .closeWindow, .quit:
            return true
        }
    }

    // MARK: - Open panel

    /// impl: MEDIA-001 rule 1 — filtered to the format catalog, multiple
    /// selection and directories allowed; cancelling changes nothing.
    func openDocument() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = FormatCatalog.openPanelContentTypes
        panel.prompt = "Play"

        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            guard response == .OK, !panel.urls.isEmpty else {
                // impl: MEDIA-001-S2 — cancelling logs and does nothing else.
                log(.mediaOpenCancelled, .info, [:])
                return
            }
            self.opener.open(urls: panel.urls, reason: .openPanel)
        }
    }
}
