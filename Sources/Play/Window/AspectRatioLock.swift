// impl: WIN-003 rules 1, 5, 6, 12, 14, 15 — the window is the shape of the film.
//
// `contentAspectRatio` is the whole mechanism of rule 5: AppKit's own resize
// loop honours it on all eight handles, so the picture can never be letterboxed
// by the window. What this file owns is *when* it is set, to what, and when it
// must be let go of (fullscreen, rule 14).

import AppKit

@MainActor
final class AspectRatioLock {
    private unowned let window: NSWindow
    private unowned let player: MediaPlayer

    /// The last display aspect ratio libvlc reported. Survives a suspension,
    /// because rule 15 applies it on the way out of fullscreen.
    private(set) var lockedRatio: CGFloat?
    private(set) var isSuspended = false

    init(window: NSWindow, player: MediaPlayer) {
        self.window = window
        self.player = player
    }

    // MARK: - The video's shape

    /// impl: WIN-003 rule 1 — `Vout` is the earliest event at which
    /// `libvlc_video_get_size` answers anything but 0 x 0. Wired by AppDelegate
    /// to `PlaybackState.onVoutChanged`; nothing else calls this.
    func videoDidAppear() {
        guard let reported = player.videoDisplayGeometry(),
              let geometry = VideoGeometry(pixelSize: reported.pixelSize,
                                           sarNum: reported.sarNum,
                                           sarDen: reported.sarDen) else {
            // impl: WIN-003 rule 12 — a vout with no usable size is otherwise
            // indistinguishable from no vout at all.
            log(.windowAspectRatioUnavailable, .warn, ["reason": "voutWithoutSize"])
            return
        }

        let ratio = geometry.displayAspectRatio
        guard ratio.isFinite, ratio > 0 else {
            log(.windowAspectRatioUnavailable, .warn, ["reason": "nonFiniteRatio"])
            return
        }
        // impl: WIN-003 rule 6 — the ratio is re-applied only when it changes;
        // every ES event of a long file would otherwise re-centre the window.
        let unchanged = lockedRatio.map { abs($0 - ratio) < 0.001 } ?? false
        lockedRatio = ratio
        guard !unchanged else { return }

        let applied = isSuspended ? window.contentRect(forFrameRect: window.frame).size
                                  : apply(ratio: ratio)

        // impl: WIN-003 rule 12 — the pixel size *and* the SAR it was combined
        // with, because the two together are what WIN-003-S1 discriminates.
        // Built key by key: one literal of this width is a minute of type-checking.
        var payload: [String: Any] = [:]
        payload["videoW"] = Int(geometry.pixelSize.width)
        payload["videoH"] = Int(geometry.pixelSize.height)
        payload["sarNum"] = reported.sarNum
        payload["sarDen"] = reported.sarDen
        payload["dar"] = Double(ratio)
        payload["contentW"] = Int(applied.width)
        payload["contentH"] = Int(applied.height)
        payload["minW"] = Int(window.contentMinSize.width)
        payload["minH"] = Int(window.contentMinSize.height)
        payload["suspended"] = isSuspended
        payload["screenID"] = Self.screenID(window)
        log(.windowSizedToVideo, .info, payload)
    }

    /// impl: WIN-003 rules 5, 6, 13 — set the constraint, then make the window
    /// obey it immediately; `contentAspectRatio` governs the *next* user resize
    /// and does not reshape a window that is already the wrong shape.
    @discardableResult
    private func apply(ratio: CGFloat) -> NSSize {
        window.contentAspectRatio = NSSize(width: ratio, height: 1)
        window.contentMinSize = VideoGeometry.minimumContentSize(ratio: ratio)

        let visible = (window.screen ?? NSScreen.main)?.visibleFrame
        let current = window.contentRect(forFrameRect: window.frame).size
        let content = VideoGeometry.contentSize(ratio: ratio, keepingWidthOf: current,
                                                within: visible?.size)
        let frameSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: content)).size
        var frame = VideoGeometry.recentred(window.frame, toFrameSize: frameSize)
        if let visible { frame = VideoGeometry.nudgedInside(frame, visibleFrame: visible) }
        window.setFrame(frame, display: true, animate: false)
        return content
    }

    // MARK: - Fullscreen (rules 14, 15)

    /// impl: WIN-003 rule 14 — called only by FullscreenController, from
    /// `windowWillEnterFullScreen`, i.e. before AppKit picks the fullscreen size.
    func suspendForFullscreen() {
        guard !isSuspended else { return }
        isSuspended = true
        window.contentAspectRatio = .zero
        window.contentMinSize = VideoGeometry.unlockedMinimum
        log(.windowAspectRatioSuspended, .info, ["reason": "fullscreen"])
    }

    /// impl: WIN-003 rules 14, 15 — the ratio that arrived while suspended is
    /// applied here, which is why `lockedRatio` is updated even when the window
    /// is not touched.
    func restoreAfterFullscreen() {
        guard isSuspended else { return }
        isSuspended = false
        guard let ratio = lockedRatio else {
            // `dar` stays a Double even here, so a reader never has to handle
            // two types for one key.
            log(.windowAspectRatioRestored, .info, ["dar": Double(0), "reason": "noVideo"])
            return
        }
        let content = apply(ratio: ratio)
        log(.windowAspectRatioRestored, .info, [
            "dar": Double(ratio),
            "contentW": Int(content.width), "contentH": Int(content.height),
        ])
    }

    private static func screenID(_ window: NSWindow) -> Int {
        Int(window.screen?.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 ?? 0)
    }
}
