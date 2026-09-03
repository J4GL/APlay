// impl: VLC-001 rules 14, 17 · VLC-002 rule 3 · WIN-001 · MEDIA-001 rules 3-5 —
// the assembly point. This file is the only place that wires the modules
// together; see docs/call-graph.md.

import AppKit
import PlayA11y

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let state = PlaybackState()
    private let geometryLog = WindowGeometryLog()
    /// impl: WIN-003 rules 8-11 — the window-frame store; construction alone
    /// never touches AppKit, so it is safe this early.
    private let geometryStore = WindowGeometryStore()
    /// impl: WIN-003 rule 4 — whether `buildWindow` restored a saved frame,
    /// read by `buildEngine` when constructing `AspectRatioLock`.
    private var didRestoreGeometry = false
    /// impl: LIST-001 rule 2 — session state, owned here and never persisted.
    private let queue = Queue()

    private var window: BorderlessWindow?
    private var contentRoot: ContentRootView?
    private var videoView: VideoHostView?
    private var player: MediaPlayer?
    private var transport: TransportController?
    private var seeker: SeekController?
    private var volume: VolumeController?
    private var fullscreen: FullscreenController?
    /// impl: WIN-003 rule 5 — held for the session; both its references
    /// (the window and the player) are `unowned`.
    private var aspectRatio: AspectRatioLock?
    private var commands: AppCommands?
    private var opener: FileOpener?
    private var dropTarget: DropTarget?
    private var hud: HUDView?
    private var autoHide: AutoHideController?
    private var trackCatalog: TrackCatalog?
    private var subtitles: SubtitleController?
    private var audioTracks: AudioTrackController?
    private var subtitleDelay: SubtitleDelayController?
    private var delayReadout: TransientReadout?
    private var advancer: QueueAdvancer?
    private var queuePanel: QueueOverlayView?
    /// impl: MEDIA-002 rules 7, 10 — the failure banner and the coalescing
    /// state that turns a synchronous all-fail queue cascade into one summary.
    private var failureBanner: FailureBanner?
    private var pendingQueueFailures: [(MediaFailure, URL)] = []
    private var queueFlushScheduled = false
    private var queueFullyFailed = false
    /// impl: PLAY-004 — the resume-position store, its coordinator, and toast.
    private var resumeStore: ResumeStore?
    private var resumeCoordinator: ResumeCoordinator?
    private var resumeToast: ResumeToast?
    /// impl: PREF-001 rules 9, 14 — the stored preference, and the window that
    /// edits it. Both live for the whole session.
    private var preferences: TrackPreferencesStore?
    private var preferencesWindow: PreferencesWindowController?
    /// impl: CTRL-004 rule 1 — held for the session; `NSApp.mainMenu` does not
    /// retain the delegate that keeps the track lists current.
    private var mainMenu: MainMenu?

    /// impl: MEDIA-001 rule 4 — URLs collected before the window exists are
    /// opened once it does.
    private var pendingURLs: [URL] = []

    // MARK: - Launch

    /// impl: LOG-001 rule 1 — the log starts before the engine, so a bootstrap
    /// failure is itself captured.
    func applicationWillFinishLaunching(_ notification: Notification) {
        EventLog.shared.start()
        log(.appLaunchOk, .info, ["pid": Int(ProcessInfo.processInfo.processIdentifier)])

        do {
            try VLCRuntime.shared.bootstrap()
        } catch let failure as VLCRuntime.BootstrapFailure {
            presentBootstrapFailure(failure)
            return
        } catch {
            presentBootstrapFailure(.libvlcNewReturnedNull)
            return
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard VLCRuntime.shared.instance != nil else { return }
        buildWindow()
        buildEngine()
        openCommandLineArguments()
    }

    // MARK: - Window

    /// impl: WIN-001 rules 1-6 · WIN-003 rules 4, 9 — created once, here and
    /// nowhere else. A saved geometry restores position *and* size directly
    /// (rule 4's "unless a saved geometry applies"); otherwise the default
    /// 960 x 540 rect is centred on the screen containing the cursor.
    private func buildWindow() {
        let restored = geometryStore.restore()
        didRestoreGeometry = restored != nil
        let initial = restored ?? NSRect(x: 0, y: 0, width: 960, height: 540)
        let window = BorderlessWindow(contentRect: initial)

        let root = ContentRootView(frame: initial)
        root.autoresizingMask = [.width, .height]
        let video = VideoHostView(frame: root.bounds)
        video.autoresizingMask = [.width, .height]
        root.addSubview(video)
        window.contentView = root

        // impl: WIN-001 rule 8 rung 1 — the ladder starts here; the rung reached
        // is recorded only once WIN-001-H2 passes with a real screenshot.
        WindowShapeController.applyCornerRadius(WindowShapeController.cornerRadius, to: root)

        geometryLog.onWindowWillClose = { NSApp.terminate(nil) }
        geometryLog.store = geometryStore
        window.delegate = geometryLog
        if let restored {
            window.setFrame(restored, display: false)
        } else {
            // impl: WIN-003 rule 4 — centred on the screen containing the
            // mouse cursor at open time, not always the main screen.
            window.setFrame(Self.centeredOnCursorScreen(initial.size), display: false)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        geometryLog.logCreated(window)

        self.window = window
        self.contentRoot = root
        self.videoView = video
    }

    /// impl: WIN-003 rule 4 — mirrors `NSWindow.center()`'s own math, targeting
    /// the screen under the mouse instead of always the main screen.
    private static func centeredOnCursorScreen(_ size: NSSize) -> NSRect {
        let cursor = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(cursor) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else {
            return NSRect(origin: .zero, size: size)
        }
        return NSRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    // MARK: - Engine

    /// impl: VLC-002 rule 1 — one media player, created here, reused for every item.
    private func buildEngine() {
        guard let videoView, let window,
              let player = MediaPlayer(runtime: VLCRuntime.shared, state: state) else {
            presentBootstrapFailure(.libvlcNewReturnedNull)
            return
        }
        // impl: VLC-001 rule 16 — video output goes to the borderless window's view.
        player.attachVideoOutput(to: videoView)

        let opener = FileOpener(player: player, state: state, queue: queue)
        opener.onFailure = { [weak self] failure, url in
            self?.reportMediaFailure(failure, url, coalesce: true)
        }

        // impl: PREF-001 rules 9, 12 — read before the track controllers exist,
        // because the very first `applyDefault()` must already see it.
        let preferences = TrackPreferencesStore()

        // impl: TRACK-001 / TRACK-002 / TRACK-003 — the track stack. The catalog
        // is rebuilt from ES events; the controllers own their libvlc surface.
        let catalog = TrackCatalog(player: player)
        let subtitles = SubtitleController(player: player, catalog: catalog,
                                           preferences: preferences)
        let audioTracks = AudioTrackController(player: player, catalog: catalog,
                                               preferences: preferences)
        // impl: PREF-001 rule 12 — a change reaches the media already playing.
        // Only the affected list is reconsidered, and `userHasChosen` inside each
        // controller is what stops a default from overriding a hand-picked track.
        preferences.onChange = { kind in
            switch kind {
            case .audio: audioTracks.applyDefault()
            case .subtitle: subtitles.applyDefault()
            }
        }
        let subtitleDelay = SubtitleDelayController(player: player, subtitles: subtitles)
        subtitles.onFailure = { [weak self] failure, url in
            // impl: MEDIA-002 rule 10 — a subtitle-attach failure has no queue
            // index and must always present immediately, never batched into a
            // queue-cascade summary.
            self?.reportMediaFailure(failure, url, coalesce: false)
        }
        catalog.onSubtitlesChanged = { [weak self] in
            subtitles.catalogChanged()
            self?.hud?.refresh()
        }
        catalog.onAudioChanged = { [weak self] in
            audioTracks.catalogChanged()
            self?.hud?.refresh()
        }
        subtitles.onChange = { [weak self] in self?.hud?.refresh() }
        audioTracks.onChange = { [weak self] in self?.hud?.refresh() }
        opener.subtitles = subtitles

        state.onChange = { [weak self] in self?.playbackStateChanged() }
        state.onTracksChanged = { catalog.rebuild() }
        // impl: TRACK-001 rule 6 · TRACK-002 rule 5 · TRACK-003 rule 9
        state.onMediaChanged = {
            catalog.resetForNewMedia()
            subtitles.resetForNewMedia()
            audioTracks.resetForNewMedia()
            subtitleDelay.resetForNewMedia()
        }

        // impl: MEDIA-001 rules 1-2 — the drop and ⌘O routes, both funnelling
        // into the same FileOpener as the command line.
        let dropTarget = DropTarget(opener: opener, host: videoView)
        videoView.dropTarget = dropTarget

        let transport = TransportController(player: player, state: state)
        let seeker = SeekController(player: player, state: state)

        // impl: PLAY-004 — per-file resume position: store, coordinator, toast.
        let resumeStore = ResumeStore()
        let resumeCoordinator = ResumeCoordinator(store: resumeStore, state: state, seeker: seeker)
        resumeCoordinator.currentMrlHash = { [weak opener] in opener?.currentMrlHash }
        state.onPlayingChanged = { [weak resumeCoordinator] isPlaying in
            resumeCoordinator?.setTicking(isPlaying)
        }
        state.onEndedForResume = { [weak self, weak resumeCoordinator] in
            resumeCoordinator?.handleEnded(mrlHash: self?.opener?.currentMrlHash)
        }
        transport.resumeCoordinator = resumeCoordinator
        seeker.onSeekOccurred = { [weak resumeCoordinator] in resumeCoordinator?.noteSeekOccurred() }
        opener.resumeCoordinator = resumeCoordinator
        self.resumeStore = resumeStore
        self.resumeCoordinator = resumeCoordinator

        let volume = VolumeController(player: player)
        let fullscreen = FullscreenController(window: window, contentRoot: contentRoot ?? videoView)
        geometryLog.fullscreen = fullscreen

        // impl: WIN-003 rules 1, 5, 14 — the window takes the video's shape at
        // the first vout, keeps it through every resize, and lets go of it for
        // the duration of fullscreen.
        let aspectRatio = AspectRatioLock(window: window, player: player,
                                          didRestoreGeometry: didRestoreGeometry)
        state.onVoutChanged = { aspectRatio.videoDidAppear() }
        fullscreen.aspectRatio = aspectRatio

        // impl: LIST-001 rules 5-8 — the queue's mover. `load` is the only way
        // an item reaches libvlc, and it is the opener's one entry point.
        let advancer = QueueAdvancer(queue: queue, state: state, seeker: seeker)
        advancer.load = { [weak opener] item, index in opener?.load(item: item, index: index) }
        advancer.onAllItemsFailed = { [weak self] in self?.reportQueueExhausted() }
        opener.advancer = advancer
        state.onEndReached = { advancer.advanceAutomatically() }
        // impl: MEDIA-002 rules 6-7 — libvlc's own async decode error for the
        // media currently loaded, distinct from FileOpener's preflight failures.
        state.onEncounteredError = { [weak self] in self?.handleEncounteredError() }
        // impl: LIST-001 rule 12 / LIST-002 rules 5-6 — the HUD's queue controls
        // and the panel's rows are both redrawn from the model, never patched.
        queue.onChange = { [weak self] in
            self?.hud?.refresh()
            self?.queuePanel?.rebuild()
        }

        // impl: PREF-001 rule 14 — built here so ⌘, has something to open from
        // the first keystroke; the window itself is created lazily on first use.
        let preferencesWindow = PreferencesWindowController(store: preferences)

        let commands = AppCommands(opener: opener, transport: transport, seeker: seeker,
                                   volume: volume, fullscreen: fullscreen,
                                   subtitles: subtitles, audioTracks: audioTracks,
                                   subtitleDelay: subtitleDelay, advancer: advancer,
                                   state: state, preferences: preferencesWindow,
                                   window: window)
        window.commands = commands

        buildHUD(transport: transport, seeker: seeker, volume: volume,
                 fullscreen: fullscreen, subtitles: subtitles, audioTracks: audioTracks,
                 subtitleDelay: subtitleDelay, advancer: advancer,
                 commands: commands, videoView: videoView)

        self.player = player
        self.transport = transport
        self.seeker = seeker
        self.volume = volume
        self.fullscreen = fullscreen
        self.aspectRatio = aspectRatio
        self.commands = commands
        self.opener = opener
        self.dropTarget = dropTarget
        self.advancer = advancer
        self.trackCatalog = catalog
        self.subtitles = subtitles
        self.audioTracks = audioTracks
        self.subtitleDelay = subtitleDelay
        self.preferences = preferences
        self.preferencesWindow = preferencesWindow
    }

    // MARK: - HUD

    /// impl: CTRL-001 rules 1, 4-7 — the overlay and its auto-hide, wired to
    /// every source of activity.
    private func buildHUD(transport: TransportController,
                          seeker: SeekController,
                          volume: VolumeController,
                          fullscreen: FullscreenController,
                          subtitles: SubtitleController,
                          audioTracks: AudioTrackController,
                          subtitleDelay: SubtitleDelayController,
                          advancer: QueueAdvancer,
                          commands: AppCommands,
                          videoView: VideoHostView) {
        // impl: LIST-002 rules 1-4 — built before the HUD so both the ⌘L route
        // (AppCommands) and the button route (HUDView) can hold it.
        let panel = QueueOverlayView(queue: queue, advancer: advancer)
        panel.onFilesDropped = { [weak self] urls in
            // impl: LIST-002 rule 12 — a drop on the panel is LIST-001 rule 4's
            // ⌥-drop, whether or not ⌥ was held.
            self?.opener?.open(urls: urls, reason: .drop, append: true)
        }
        commands.queuePanel = panel
        self.queuePanel = panel

        let hud = HUDView(state: state, transport: transport, seeker: seeker,
                          volume: volume, fullscreen: fullscreen,
                          subtitles: subtitles, audioTracks: audioTracks,
                          queue: queue, advancer: advancer) { [weak self] in
            // impl: WIN-001 rule 11 — `performClose` is a no-op without a
            // titlebar button; `close()` still posts `windowWillClose`.
            self?.window?.close()
        }
        hud.queuePanel = panel
        hud.translatesAutoresizingMaskIntoConstraints = false
        hud.alphaValue = 0
        contentRoot?.addSubview(hud)
        if let contentRoot {
            NSLayoutConstraint.activate([
                hud.leadingAnchor.constraint(equalTo: contentRoot.leadingAnchor),
                hud.trailingAnchor.constraint(equalTo: contentRoot.trailingAnchor),
                hud.bottomAnchor.constraint(equalTo: contentRoot.bottomAnchor),
                hud.topAnchor.constraint(equalTo: contentRoot.topAnchor),
            ])
        }

        // impl: LIST-002 rule 1 — added **after** the HUD, so the panel is above
        // it: the HUD's control row spans the full width, and underneath it the
        // panel's lower rows would have their clicks taken by the fullscreen and
        // queue buttons.
        contentRoot?.addSubview(panel)
        if let contentRoot { panel.installConstraints(in: contentRoot) }

        // impl: TRACK-002 rule 4 — one readout element, centred in the lower
        // third, reused across a run of key presses rather than one per press.
        let readout = TransientReadout(identifier: .overlaySubtitleDelay)
        contentRoot?.addSubview(readout)
        if let contentRoot {
            NSLayoutConstraint.activate([
                readout.centerXAnchor.constraint(equalTo: contentRoot.centerXAnchor),
                readout.bottomAnchor.constraint(equalTo: contentRoot.bottomAnchor,
                                                constant: -contentRoot.bounds.height / 4),
            ])
        }
        subtitleDelay.onReadout = { [weak readout] text in readout?.show(text) }
        self.delayReadout = readout

        // impl: MEDIA-002 rule 7 — topmost z-order; a failure must never be
        // occluded by the HUD or the queue panel.
        let banner = FailureBanner()
        contentRoot?.addSubview(banner)
        if let contentRoot {
            NSLayoutConstraint.activate([
                banner.centerXAnchor.constraint(equalTo: contentRoot.centerXAnchor),
                banner.topAnchor.constraint(equalTo: contentRoot.topAnchor, constant: 16),
                banner.widthAnchor.constraint(lessThanOrEqualTo: contentRoot.widthAnchor, multiplier: 0.8),
            ])
        }
        self.failureBanner = banner

        // impl: PLAY-004 rule 7 — top, distinct from the readout's lower
        // third and the HUD's bottom bar.
        let toast = ResumeToast()
        contentRoot?.addSubview(toast)
        if let contentRoot {
            NSLayoutConstraint.activate([
                toast.centerXAnchor.constraint(equalTo: contentRoot.centerXAnchor),
                toast.topAnchor.constraint(equalTo: contentRoot.topAnchor, constant: 16),
            ])
        }
        resumeCoordinator?.onOffer = { [weak toast] record in toast?.show(record) }
        resumeCoordinator?.onDismissRequested = { [weak toast] reason in toast?.dismiss(reason: reason) }
        resumeCoordinator?.onAccepted = { [weak toast] in toast?.hideForAcceptance() }
        toast.onResume = { [weak self] record in self?.resumeCoordinator?.handleAccepted(record: record) }
        toast.onDismiss = { [weak self] reason in self?.resumeCoordinator?.handleDismissed(reason: reason) }
        self.resumeToast = toast

        let autoHide = AutoHideController()
        // impl: CTRL-001 rules 4-5 — fade in 150 ms, out 300 ms.
        autoHide.onVisibilityChange = { visible in
            NSAnimationContext.runAnimationGroup { context in
                context.duration = visible ? 0.15 : 0.3
                hud.animator().alphaValue = visible ? 1 : 0
            }
        }
        hud.onSuppress = { autoHide.suppress($0) }
        hud.onRelease = { autoHide.release($0) }
        readout.onSuppress = { autoHide.suppress($0) }
        readout.onRelease = { autoHide.release($0) }
        banner.onSuppress = { autoHide.suppress($0) }
        banner.onRelease = { autoHide.release($0) }
        // impl: LIST-002 rule 4 — the HUD must not hide out from under an open
        // list; the reason is logged, not merely a boolean.
        panel.onSuppress = { autoHide.suppress($0) }
        panel.onRelease = { autoHide.release($0) }

        videoView.onMouseMoved = { autoHide.noteActivity(trigger: .mouseMove) }
        videoView.onMouseExited = { autoHide.pointerExitedWindow() }
        videoView.onSingleClick = { [weak panel] in
            // impl: LIST-002 rule 2 — clicking the video outside the panel
            // closes it, and that click does nothing else: dismissing an
            // overlay must not also pause the film.
            if panel?.close(trigger: .outsideClick) == true { return }
            transport.toggle(element: A11yID.windowVideoView.rawValue)
        }
        videoView.onDoubleClick = {
            fullscreen.toggle(element: A11yID.windowVideoView.rawValue)
        }
        // impl: PLAY-003 rule 3 — ±2 % per notch, with the HUD revealed so the
        // user sees what they are changing.
        videoView.onScroll = { delta in
            guard delta != 0 else { return }
            volume.adjust(byPercent: delta > 0 ? 2 : -2, source: "scroll",
                          element: A11yID.windowVideoView.rawValue)
            autoHide.noteActivity(trigger: .mouseMove)
        }
        commands.onActivity = { autoHide.noteActivity(trigger: $0) }
        volume.onChange = { hud.refresh() }

        // impl: CTRL-004 rule 6 — the HUD stays the owner of the shuffle state;
        // the menu toggles it and reads it back rather than keeping a copy.
        commands.onToggleShuffle = { [weak hud] in hud?.toggleShuffle() ?? false }
        commands.isShuffled = { [weak hud] in hud?.isShuffled ?? false }

        self.hud = hud
        self.autoHide = autoHide

        // impl: CTRL-004 rule 1 — built last, because it needs every controller
        // above. `docs/call-graph.md` used to place `MainMenu.build()` in
        // `willFinishLaunching`; nothing it depends on exists that early.
        let mainMenu = MainMenu(commands: commands, subtitles: subtitles,
                                audioTracks: audioTracks, fullscreen: fullscreen)
        // impl: CTRL-004 rule 13 — the same suppression the HUD's own popups use.
        mainMenu.onSuppress = { autoHide.suppress($0) }
        mainMenu.onRelease = { autoHide.release($0) }
        mainMenu.install()
        self.mainMenu = mainMenu
    }

    /// impl: PLAY-001 rule 1 — every view reads status from PlaybackState.
    private func playbackStateChanged() {
        let showEmptyState = switch state.status {
        case .idle, .failed: true
        default: false
        }
        videoView?.setEmptyStateVisible(showEmptyState)
        hud?.refresh()

        // impl: CTRL-001 rules 4-5 — the HUD is always up when not playing, and
        // auto-hide is suppressed for exactly as long as that is true.
        if state.status == .playing {
            // impl: PLAY-003 rule 6 — libvlc resets the player's volume when the
            // media changes, so the stored level is applied to each new item.
            volume?.reapplyToCurrentMedia()
            autoHide?.release(.notPlaying)
        } else {
            autoHide?.suppress(.notPlaying)
            autoHide?.noteActivity(trigger: .stateChange)
        }
    }

    // MARK: - Media routes

    /// impl: MEDIA-001 rule 4 — the route the test harness uses.
    ///
    /// Only arguments that name an existing file are taken as media. Anything
    /// else on the command line belongs to someone else — `-key value` pairs
    /// land in `NSArgumentDomain` for `UserDefaults`, and treating their values
    /// as paths would file a bogus `media.open.requested` count.
    private func openCommandLineArguments() {
        let paths = CommandLine.arguments.dropFirst().filter {
            !$0.hasPrefix("-") && FileManager.default.fileExists(atPath: $0)
        }
        let urls = paths.map { URL(fileURLWithPath: $0) } + pendingURLs
        pendingURLs.removeAll()
        guard !urls.isEmpty else { return }
        opener?.open(urls: urls, reason: .commandLine)
    }

    /// impl: MEDIA-001 rules 3, 5 — Finder "Open With"; reuses the one window.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let opener else {
            pendingURLs.append(contentsOf: urls)
            return
        }
        opener.open(urls: urls, reason: .launchServices)
    }

    // MARK: - Failure presentation

    /// impl: VLC-001 rule 17 / MEDIA-002 rule 7 — bootstrap failure is the one
    /// modal, because the app genuinely cannot continue.
    private func presentBootstrapFailure(_ failure: VLCRuntime.BootstrapFailure) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = failure.message
        alert.informativeText = "APlay cannot start without its video engine."
        alert.addButton(withTitle: "Quit")
        alert.window.setAccessibilityIdentifier(A11yID.alertBootstrapFailure.rawValue)
        alert.runModal()
        EventLog.shared.flushAndClose()
        NSApp.terminate(nil)
    }

    /// impl: MEDIA-002 rule 6 — the one place `.encounteredError` becomes an
    /// observable failure: libvlc's own async decode error, distinct from
    /// FileOpener's synchronous preflight checks. PlaybackState stays
    /// URL-unaware by design, so the failing item's identity is read from
    /// `Queue` here, the only place that already owns it.
    private func handleEncounteredError() {
        guard let index = queue.currentIndex, let url = queue.current?.url else { return }
        log(.mediaOpenFailed, .error, [
            "reason": MediaFailure.decodeFailed.reason,
            "redactedName": PathRedactor.redact(url),
            "timedOut": false,
        ])
        reportMediaFailure(.decodeFailed, url, coalesce: true)
        advancer?.skipFailed(at: index)
    }

    /// impl: MEDIA-002 rules 7, 10 — presents the banner, or — for a queue
    /// cascade — buffers until the synchronous run of failures is known to
    /// have exhausted the whole queue or not. `QueueAdvancer.skipFailed`'s
    /// cascade is fully synchronous (each failure loads the next item within
    /// the same call stack), and `onAllItemsFailed` — wired to
    /// `queueFullyFailed = true` below — always fires strictly after every
    /// individual failure in that stack, so deferring one run-loop turn lets
    /// the flush see whether it happened before deciding what to show.
    private func reportMediaFailure(_ failure: MediaFailure, _ url: URL, coalesce: Bool) {
        guard coalesce, advancer?.hasQueue == true else {
            failureBanner?.present(failure, for: url)
            return
        }
        pendingQueueFailures.append((failure, url))
        guard !queueFlushScheduled else { return }
        queueFlushScheduled = true
        DispatchQueue.main.async { [weak self] in self?.flushQueueFailures() }
    }

    /// impl: LIST-001 rule 8 / MEDIA-002 rule 10 — when *every* item failed the
    /// user gets one summary banner, not one per item.
    private func reportQueueExhausted() {
        queueFullyFailed = true
    }

    private func flushQueueFailures() {
        queueFlushScheduled = false
        defer { pendingQueueFailures.removeAll(); queueFullyFailed = false }
        guard !pendingQueueFailures.isEmpty else { return }
        if queueFullyFailed {
            failureBanner?.presentSummary(count: queue.items.count)
        } else if let last = pendingQueueFailures.last {
            failureBanner?.present(last.0, for: last.1)
        }
    }

    // MARK: - Termination

    /// impl: VLC-002 rule 3 — detach → stop → release player → release instance.
    func applicationWillTerminate(_ notification: Notification) {
        state.releaseSleepAssertionForTermination()
        resumeCoordinator?.saveCurrent(reason: "terminate")
        // impl: WIN-003 rule 8 — skip a fullscreen frame; it covers the whole
        // screen and is not a real windowed state to restore into.
        if let window, fullscreen?.isFullscreen != true {
            geometryStore.save(window.frame)
        }
        opener?.shutdown()
        player?.shutdown()
        VLCRuntime.shared.shutdown()
        log(.appTerminateOk, .info, [:])
        EventLog.shared.flushAndClose()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
