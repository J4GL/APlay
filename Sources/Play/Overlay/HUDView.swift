// impl: CTRL-001 rules 1-3, 9-12 — the overlay itself.
//
// Bottom bar only. No top bar, no title text, no filename: the picture is the
// content, and anything else is the chrome this player exists to avoid.

import AppKit
import PlayA11y

@MainActor
final class HUDView: NSView {
    /// impl: CTRL-001 rule 2 — 120 pt gradient, not a hard-edged bar.
    private static let backdropHeight: CGFloat = 120
    /// impl: CTRL-001 rule 10 — below this width the layout goes compact.
    private static let compactWidthThreshold: CGFloat = 480

    private let state: PlaybackState
    private let transport: TransportController
    private let seeker: SeekController
    private let volume: VolumeController
    private let subtitles: SubtitleController
    private let audioTracks: AudioTrackController
    private let queue: Queue
    private let advancer: QueueAdvancer

    private let backdrop = CAGradientLayer()
    private let seekBar: SeekBar
    private let volumeSlider: VolumeSlider
    private let elapsedLabel = NSTextField(labelWithString: "0:00")
    private let remainingLabel = NSTextField(labelWithString: "-0:00")

    private let playPauseButton: HUDButton
    private let previousButton: HUDButton
    private let nextButton: HUDButton
    private let muteButton: HUDButton
    private let fullscreenButton: HUDButton
    private let closeButton: HUDButton
    private var subtitleMenuButton: HUDButton!
    private var audioMenuButton: HUDButton!
    private var queueButton: HUDButton!
    private var shuffleButton: HUDButton!
    private var overflowButton: HUDButton!
    private var controlRow: NSStackView!

    private var isCompact = false
    /// impl: LIST-001 rule 11 — session state, off by default. The HUD stays the
    /// owner of it; CTRL-004's menu item only reflects and toggles it, so the
    /// button's tint and the menu's check mark cannot disagree.
    private(set) var isShuffled = false

    /// impl: LIST-002 rule 2 — set by AppDelegate; the panel is built with the
    /// HUD and owned by the content root.
    weak var queuePanel: QueueOverlayView?

    /// impl: CTRL-001 rule 5 — pointer-inside and drag suppressions, paired.
    var onSuppress: ((HUDSuppression) -> Void)?
    var onRelease: ((HUDSuppression) -> Void)?

    init(state: PlaybackState,
         transport: TransportController,
         seeker: SeekController,
         volume: VolumeController,
         fullscreen: FullscreenController,
         subtitles: SubtitleController,
         audioTracks: AudioTrackController,
         queue: Queue,
         advancer: QueueAdvancer,
         onClose: @escaping () -> Void) {
        self.state = state
        self.transport = transport
        self.seeker = seeker
        self.volume = volume
        self.subtitles = subtitles
        self.audioTracks = audioTracks
        self.queue = queue
        self.advancer = advancer
        self.seekBar = SeekBar(seeker: seeker, state: state)
        self.volumeSlider = VolumeSlider(volume: volume)

        playPauseButton = HUDButton(identifier: .hudPlayPauseButton, symbol: "play.fill",
                                    accessibilityLabel: "Play", pointSize: 17) {
            transport.toggle(element: A11yID.hudPlayPauseButton.rawValue)
        }
        // impl: LIST-001 rule 6 — the buttons are the same two calls the ⌘[ and
        // ⌘] keys make, so the 3 s previous/restart rule cannot differ between
        // mouse and keyboard.
        previousButton = HUDButton(identifier: .hudPreviousButton, symbol: "backward.end.fill",
                                   accessibilityLabel: "Previous") {
            advancer.previousOrRestart(element: A11yID.hudPreviousButton.rawValue)
        }
        nextButton = HUDButton(identifier: .hudNextButton, symbol: "forward.end.fill",
                               accessibilityLabel: "Next") {
            advancer.next()
        }
        muteButton = HUDButton(identifier: .hudMuteButton, symbol: "speaker.wave.2.fill",
                               accessibilityLabel: "Mute") {
            volume.toggleMute(element: A11yID.hudMuteButton.rawValue)
        }
        fullscreenButton = HUDButton(identifier: .hudFullscreenButton,
                                     symbol: "arrow.up.left.and.arrow.down.right",
                                     accessibilityLabel: "Full screen") {
            fullscreen.toggle(element: A11yID.hudFullscreenButton.rawValue)
        }
        closeButton = HUDButton(identifier: .hudCloseButton, symbol: "xmark",
                                accessibilityLabel: "Close", pointSize: 13) {
            // impl: WIN-001 rule 15
            log(.windowCloseClicked, .info, ["element": A11yID.hudCloseButton.rawValue])
            onClose()
        }

        super.init(frame: .zero)

        // impl: TRACK-001 rule 7 / TRACK-003 rule 7 — the menu buttons. Built
        // after `super.init` because presenting a menu needs the button's own
        // view as its anchor, which does not exist until then.
        subtitleMenuButton = HUDButton(identifier: .hudSubtitleMenuButton,
                                       symbol: "captions.bubble",
                                       accessibilityLabel: "Subtitles") { [weak self] in
            self?.presentTrackMenu(.subtitles)
        }
        audioMenuButton = HUDButton(identifier: .hudAudioMenuButton,
                                    symbol: "waveform",
                                    accessibilityLabel: "Audio track") { [weak self] in
            self?.presentTrackMenu(.audio)
        }
        // impl: LIST-002 rule 2 — the same toggle ⌘L performs.
        queueButton = HUDButton(identifier: .hudQueueButton, symbol: "list.bullet",
                                accessibilityLabel: "Queue") { [weak self] in
            self?.queuePanel?.toggle(trigger: .button)
        }
        // impl: LIST-001 rule 11 / LIST-002 rule 11 — shuffles the pending tail
        // and shows its on-state in the accent colour.
        shuffleButton = HUDButton(identifier: .hudShuffleButton, symbol: "shuffle",
                                  accessibilityLabel: "Shuffle") { [weak self] in
            self?.toggleShuffle()
        }
        // impl: CTRL-001 rule 10 — at the minimum window size the queue
        // controls collapse behind this rather than being clipped.
        overflowButton = HUDButton(identifier: .hudOverflowButton, symbol: "ellipsis",
                                   accessibilityLabel: "More controls") { [weak self] in
            self?.presentOverflowMenu()
        }

        wantsLayer = true
        setAccessibilityIdentifier(A11yID.hudRoot.rawValue)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        buildLayout()
        seekBar.onDragStateChange = { [weak self] dragging in
            guard let self else { return }
            dragging ? onSuppress?(.dragInProgress) : onRelease?(.dragInProgress)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Play builds no nibs") }

    // MARK: - Layout

    /// impl: CTRL-001 rule 1
    private func buildLayout() {
        // rule 2 — bottom-up gradient, 65 % black to transparent.
        backdrop.colors = [
            NSColor.black.withAlphaComponent(0).cgColor,
            NSColor.black.withAlphaComponent(0.65).cgColor,
        ]
        backdrop.startPoint = CGPoint(x: 0.5, y: 1)
        backdrop.endPoint = CGPoint(x: 0.5, y: 0)
        layer?.addSublayer(backdrop)

        for label in [elapsedLabel, remainingLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            label.textColor = NSColor(white: 1, alpha: 0.85)
        }
        elapsedLabel.setAccessibilityIdentifier(A11yID.hudElapsedTime.rawValue)
        remainingLabel.setAccessibilityIdentifier(A11yID.hudRemainingTime.rawValue)

        // impl: CTRL-001 rule 1 — play/pause, previous, next, volume + mute,
        // subtitle menu, audio menu, queue, fullscreen.
        controlRow = NSStackView(views: [
            playPauseButton, previousButton, nextButton, muteButton, volumeSlider, NSView(),
            subtitleMenuButton, audioMenuButton, shuffleButton, queueButton,
            overflowButton, fullscreenButton,
        ])
        controlRow.orientation = .horizontal
        controlRow.spacing = 10
        controlRow.alignment = .centerY
        controlRow.translatesAutoresizingMaskIntoConstraints = false

        addSubview(elapsedLabel)
        addSubview(seekBar)
        addSubview(remainingLabel)
        addSubview(controlRow)
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            seekBar.leadingAnchor.constraint(equalTo: elapsedLabel.trailingAnchor, constant: 4),
            seekBar.trailingAnchor.constraint(equalTo: remainingLabel.leadingAnchor, constant: -4),
            seekBar.heightAnchor.constraint(equalToConstant: 20),
            seekBar.bottomAnchor.constraint(equalTo: controlRow.topAnchor, constant: -6),

            elapsedLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            elapsedLabel.centerYAnchor.constraint(equalTo: seekBar.centerYAnchor),
            remainingLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            remainingLabel.centerYAnchor.constraint(equalTo: seekBar.centerYAnchor),

            controlRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            controlRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            controlRow.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),

            // rule 1 — the ✕ is a top-right cluster of one.
            closeButton.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
        ])
    }

    override func layout() {
        super.layout()
        backdrop.frame = NSRect(x: 0, y: 0, width: bounds.width,
                                height: min(Self.backdropHeight, bounds.height))
        applyCompactLayoutIfNeeded()
    }

    /// impl: CTRL-001 rule 10 — at the minimum window size the time labels
    /// shorten to elapsed only and the queue controls collapse behind the
    /// overflow button. Nothing overlaps, nothing is clipped.
    private func applyCompactLayoutIfNeeded() {
        let compact = bounds.width < Self.compactWidthThreshold
        guard compact != isCompact else { return }
        isCompact = compact
        remainingLabel.isHidden = compact
        volumeSlider.isHidden = compact
        refresh()
        log(.hudLayoutCompact, .debug, ["isCompact": compact])
    }

    // MARK: - State

    /// Called by AppDelegate on every PlaybackState and volume change.
    func refresh() {
        // impl: PLAY-001 rule 3 — the glyph follows the engine, never the click.
        let playing = state.status == .playing
        playPauseButton.setSymbol(playing ? "pause.fill" : "play.fill")
        playPauseButton.setAccessibilityLabel(playing ? "Pause" : "Play")

        // impl: PLAY-003 rule 3 — the glyph reflects the level.
        muteButton.setSymbol(volumeSymbol())

        let position = seeker.displayedPositionMs
        elapsedLabel.stringValue = TimeFormat.string(forMs: position, lengthMs: state.lengthMs)
        remainingLabel.stringValue = "-" + TimeFormat.string(
            forMs: max(0, state.lengthMs - position), lengthMs: state.lengthMs)

        // impl: TRACK-003-S3 — a menu with nothing in it is worse than no menu,
        // so the audio button is absent (not disabled) on video-only media.
        // The subtitle button stays: TRACK-001 rule 3's Off row is always a
        // meaningful thing to show.
        audioMenuButton.isHidden = audioTracks.tracks.isEmpty

        // impl: LIST-001 rule 12 / CTRL-001 rule 3 — controls for a queue that
        // does not exist are clutter, so they are absent rather than disabled.
        // impl: CTRL-001 rule 10 — and in the compact layout they move into the
        // overflow menu rather than being clipped.
        let hasQueue = queue.hasMultipleItems
        previousButton.isHidden = !hasQueue || isCompact
        nextButton.isHidden = !hasQueue || isCompact
        queueButton.isHidden = !hasQueue || isCompact
        shuffleButton.isHidden = !hasQueue || isCompact
        overflowButton.isHidden = !(hasQueue && isCompact)
        // impl: LIST-001-S2 / CTRL-001 rule 3 — "applies but unavailable" at the
        // last item: 40 % opacity, not gone.
        nextButton.isEnabled = queue.nextPending(after: queue.currentIndex) != nil
        shuffleButton.setTint(isShuffled ? .controlAccentColor : .white)

        // impl: CTRL-001 rule 3 — applies but unavailable → 40 % opacity.
        seekBar.isHidden = false
        seekBar.refresh()
        volumeSlider.refresh()
    }

    /// impl: TRACK-001 rule 7 / TRACK-003 rule 7 — the menu route into the same
    /// controllers the `S` and `A` keys use.
    private func presentTrackMenu(_ kind: TrackMenu.Kind) {
        switch kind {
        case .subtitles:
            TrackMenu.present(
                kind: .subtitles, tracks: subtitles.tracks, selectedID: subtitles.selectedID,
                below: subtitleMenuButton,
                onSelect: { [weak self] id in self?.subtitles.select(id, source: .user) },
                onOpen: { [weak self] in self?.onSuppress?(.menuOpen) },
                onClose: { [weak self] in self?.onRelease?(.menuOpen) })
        case .audio:
            TrackMenu.present(
                kind: .audio, tracks: audioTracks.tracks, selectedID: audioTracks.selectedID,
                below: audioMenuButton,
                onSelect: { [weak self] id in self?.audioTracks.select(id, source: .user) },
                onOpen: { [weak self] in self?.onSuppress?(.menuOpen) },
                onClose: { [weak self] in self?.onRelease?(.menuOpen) })
        }
    }

    /// impl: LIST-001 rule 11 — shuffling reorders the *pending* tail only, so
    /// what was just watched cannot come back round.
    ///
    /// impl: CTRL-004 rule 6 — also the menu's route, which is why it is
    /// internal and returns the new state: the menu asks the HUD rather than
    /// keeping a second copy of it.
    @discardableResult
    func toggleShuffle() -> Bool {
        isShuffled.toggle()
        if isShuffled { queue.shufflePending() }
        refresh()
        return isShuffled
    }

    /// impl: CTRL-001 rule 10 — the compact layout's escape hatch. The items
    /// call the same controllers the buttons do, so behaviour cannot diverge
    /// between the two layouts.
    private func presentOverflowMenu() {
        let menu = NSMenu()
        menu.setAccessibilityIdentifier(A11yID.hudOverflowButton.rawValue)
        menu.addItem(withTitle: "Previous", action: #selector(overflowPrevious), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "Next", action: #selector(overflowNext), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Shuffle", action: #selector(overflowShuffle), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "Queue", action: #selector(overflowQueue), keyEquivalent: "")
            .target = self
        onSuppress?(.menuOpen)
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: overflowButton.bounds.height), in: overflowButton)
        onRelease?(.menuOpen)
    }

    @objc private func overflowPrevious() {
        advancer.previousOrRestart(element: A11yID.hudPreviousButton.rawValue)
    }
    @objc private func overflowNext() { advancer.next() }
    @objc private func overflowShuffle() { toggleShuffle() }
    @objc private func overflowQueue() { queuePanel?.toggle(trigger: .button) }

    private func volumeSymbol() -> String {
        if volume.isMuted || volume.percent == 0 { return "speaker.slash.fill" }
        if volume.percent < 40 { return "speaker.wave.1.fill" }
        if volume.percent < 90 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    // MARK: - Pointer

    /// impl: CTRL-001 rule 5 — "inside the HUD" means inside a region that
    /// actually carries controls. The root view spans the whole window so the
    /// gradient can reach the bottom edge; tracking its full bounds would mean
    /// the pointer is *always* inside it and the HUD would never auto-hide.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        hoveredRegions.removeAll()
        for rect in trackingRegions where !rect.isEmpty {
            addTrackingArea(NSTrackingArea(
                rect: rect,
                options: [.mouseEnteredAndExited, .activeInKeyWindow],
                owner: self,
                userInfo: ["region": NSStringFromRect(rect)]))
        }
    }

    /// impl: CTRL-001 rule 15 — **tracking** regions, not hit-test rects. These
    /// are deliberately generous: the whole backdrop strip, so the HUD does not
    /// fade while the pointer merely hovers near it. The tight per-control rects
    /// used to decide dragging are `interactiveControls` below, and conflating
    /// the two would make the backdrop either inert or non-suppressing.
    private var trackingRegions: [NSRect] {
        [NSRect(x: 0, y: 0, width: bounds.width, height: min(Self.backdropHeight, bounds.height)),
         closeButton.frame.insetBy(dx: -WindowDragRegions.exclusionMargin,
                                   dy: -WindowDragRegions.exclusionMargin)]
    }

    private var hoveredRegions: Set<String> = []

    override func mouseEntered(with event: NSEvent) {
        guard let region = event.trackingArea?.userInfo?["region"] as? String else { return }
        hoveredRegions.insert(region)
        onSuppress?(.pointerInsideHUD)
    }

    override func mouseExited(with event: NSEvent) {
        guard let region = event.trackingArea?.userInfo?["region"] as? String else { return }
        hoveredRegions.remove(region)
        // Only release once the pointer has left every control region, or the
        // overlapping areas would release a suppression the other still holds.
        if hoveredRegions.isEmpty { onRelease?(.pointerInsideHUD) }
    }

    /// impl: WIN-001 rule 9.3 — the HUD itself is never a drag handle. It is
    /// only ever hit-tested for the dead band, where nothing at all should
    /// happen.
    override var mouseDownCanMoveWindow: Bool { false }

    /// impl: CTRL-001 rule 11 — the HUD never captures scroll; volume does.
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }

    /// impl: WIN-001 rule 9.3 · CTRL-001 rules 13-14 — **the** decision point
    /// for "drag moves vs. drag acts".
    ///
    /// `mouseDownCanMoveWindow` is a property of the view AppKit hit-tested, not
    /// a per-point query, so the classification has to happen here:
    ///   - on a control  → the control takes the press;
    ///   - in the 8 pt dead band → `self`, which is not a drag handle and does
    ///     nothing at all;
    ///   - anywhere else → `nil`, so the press falls through to `VideoHostView`,
    ///     which both drags the window and click-toggles playback.
    ///
    /// The last case is why the HUD may span the full window width without
    /// making that whole strip inert.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return switch WindowDragRegions.classify(local, controls: interactiveControls.map(\.rect)) {
        case .control: super.hitTest(point)
        case .deadBand: self
        case .dragHandle: nil
        }
    }

    /// impl: WIN-001 rule 16 — reachable only from the dead band, because that
    /// is the one classification whose `hitTest` returns `self`. Logged on the
    /// press rather than in `hitTest`, which runs on every mouse move.
    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        log(.windowDragRefused, .info, [
            "reason": "nearControl",
            "control": WindowDragRegions.nearestControl(to: local, among: interactiveControls)
                ?? "unknown",
        ])
    }

    /// The dead band swallows the whole click, not just its start: without this
    /// the release would travel on and toggle playback (PLAY-001 rule 5), which
    /// is exactly what rule 9.2 forbids.
    override func mouseUp(with event: NSEvent) {}

    /// impl: WIN-001 rule 9 — the *tight* frames of the genuinely interactive
    /// views, which is what "control" means here. The stack view's spacer has no
    /// accessibility identifier and is therefore not a control: it is picture,
    /// and it drags. Hidden controls are excluded, so the compact layout's
    /// collapsed buttons do not leave dead bands behind them.
    private var interactiveControls: [(name: String, rect: NSRect)] {
        var controls: [(String, NSRect)] = []
        func add(_ view: NSView) {
            guard !view.isHidden, view.superview != nil else { return }
            let id = view.accessibilityIdentifier()
            guard !id.isEmpty else { return }
            controls.append((id, convert(view.bounds, from: view)))
        }
        add(seekBar)
        add(closeButton)
        for view in controlRow.arrangedSubviews { add(view) }
        return controls
    }
}
