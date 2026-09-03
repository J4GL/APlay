// impl: MEDIA-001 rules 6-7, 11 — the single funnel every open route runs through.
//
// There is exactly one code path that turns a URL into playing media. Routes
// differ only in how they collect URLs and in the `reason` they log.

import Foundation

@MainActor
final class FileOpener {
    /// impl: MEDIA-001 rule 6 — the reasons, one per entry point.
    enum Reason: String {
        case openPanel, drop, launchServices, commandLine
    }

    private let player: MediaPlayer
    private let state: PlaybackState
    private let queue: Queue

    /// impl: LIST-001 rules 5-8 — set by AppDelegate. Weak because the advancer
    /// calls back into `load(item:index:)`, and two strong references would be a
    /// cycle for the lifetime of the app.
    weak var advancer: QueueAdvancer?

    /// impl: MEDIA-001 rule 7 — access is held for as long as the item is loaded
    /// and released when it is replaced.
    private var scopedURL: URL?

    /// impl: LIST-001 rule 8 — which queue item the current load belongs to, so
    /// a failure marks the right row and the skip continues from there.
    private var loadingIndex: Int?

    /// impl: MEDIA-002 rule 9 — the 15 s `.opening` watchdog for the item
    /// currently loading.
    private let openTimeout: OpenTimeout

    /// The reason that queued the current batch, carried onto every item it
    /// contains: an auto-advance within a dropped folder is still a drop.
    private var batchReason: Reason = .commandLine

    /// impl: MEDIA-002 rule 7 — set by AppDelegate to present the failure banner.
    var onFailure: ((MediaFailure, URL) -> Void)?

    /// impl: TRACK-001 rules 9-10 — set by AppDelegate; the sole owner of
    /// external subtitle attachment.
    var subtitles: SubtitleController?

    init(player: MediaPlayer, state: PlaybackState, queue: Queue) {
        self.player = player
        self.state = state
        self.queue = queue
        self.openTimeout = OpenTimeout(state: state)
        openTimeout.onTimeout = { [weak self] url, index in
            self?.failFromTimeout(url: url, index: index)
        }
    }

    /// impl: MEDIA-001 rule 6 — every route lands here.
    /// impl: LIST-001 rules 3-4 — `append` is the ⌥-drop; everything else
    /// replaces the queue.
    func open(urls: [URL], reason: Reason, append: Bool = false) {
        let expanded = DirectoryExpander.expand(urls)
        log(.mediaOpenRequested, .info, [
            "reason": reason.rawValue, "count": expanded.count, "append": append,
        ])

        let subtitles = expanded.filter(FormatCatalog.isSubtitle)
        // impl: MEDIA-001 rule 2 / LIST-001 rule 3 — Finder-style localised order.
        let videos = DirectoryExpander.inNameOrder(expanded.filter(FormatCatalog.isVideo))

        // impl: MEDIA-001 rule 2 / TRACK-001 rule 9 — a subtitle-only drop
        // attaches to the current item and does not disturb playback.
        guard !videos.isEmpty else {
            if subtitles.isEmpty {
                let unknown = expanded.first ?? urls.first
                if let unknown { fail(.unsupportedExtension, unknown) }
            } else {
                subtitles.forEach { attachSubtitle($0, select: true) }
            }
            return
        }

        batchReason = reason
        if append {
            // impl: LIST-001 rule 4 — appending must not disturb what is
            // playing, so it only starts playback when nothing is.
            queue.append(videos)
            if queue.currentIndex == nil { advancer?.start() }
        } else {
            queue.replace(with: videos, source: reason.rawValue)
            advancer?.start()
        }
        subtitles.forEach { attachSubtitle($0, select: true) }
    }

    /// impl: LIST-001 rule 5 — the queue's only route into libvlc. Set as
    /// `QueueAdvancer.load` by AppDelegate; called from nowhere else.
    func load(item: QueueItem, index: Int) {
        loadingIndex = index
        openSingle(item.url, reason: batchReason)
    }

    /// impl: TRACK-001 rules 9, 11 — attaching never interrupts playback, and a
    /// file that fails to load reports as `noPlayableTrack`. SubtitleController
    /// owns the slave call so the menu, the check mark and the log all come
    /// from the same place.
    private func attachSubtitle(_ url: URL, select: Bool) {
        subtitles?.addExternal(url: url, select: select)
    }

    /// impl: TRACK-001 rule 10 — sidecars whose basename matches the film are
    /// added automatically but **not** selected.
    private func attachSidecars(for url: URL) {
        let directory = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        let siblings = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])) ?? []
        let sidecars = siblings.filter {
            FormatCatalog.isSubtitle($0)
                && $0.deletingPathExtension().lastPathComponent.hasPrefix(stem)
        }
        guard !sidecars.isEmpty else { return }
        log(.tracksSubtitleSidecarsFound, .info, ["count": sidecars.count])
        sidecars.forEach { attachSubtitle($0, select: false) }
    }

    private func openSingle(_ url: URL, reason: Reason) {
        openTimeout.disarm()
        if let failure = preflight(url) {
            fail(failure, url)
            return
        }

        // impl: MEDIA-001 rule 7 — a URL that fails to start access is a failure,
        // not a silent no-op. Non-scoped URLs (command line) return false here,
        // which is why the result is only honoured for scoped routes.
        let started = url.startAccessingSecurityScopedResource()
        if !started, reason == .drop || reason == .openPanel {
            fail(.notReadable, url)
            return
        }
        releaseScopedAccess()
        if started { scopedURL = url }

        guard player.setMedia(url: url) else {
            fail(.decodeFailed, url)
            return
        }
        state.transition(to: .opening)
        openTimeout.arm(url: url, index: loadingIndex ?? -1)
        player.play()
        log(.mediaOpenOk, .info, ["mrlHash": PathRedactor.mrlHash(url), "reason": reason.rawValue])
        // The item is loaded, so a later, unrelated failure must not be
        // attributed to it (rule 8 marks rows by this index).
        loadingIndex = nil
        // impl: TRACK-001 rule 10 — after the media is set, never before.
        attachSidecars(for: url)
    }

    /// impl: MEDIA-002 rule 6 — the four cases detected before libvlc sees
    /// anything, which is why they can carry precise messages.
    private func preflight(_ url: URL) -> MediaFailure? {
        guard url.isFileURL else { return nil }   // network MRLs skip local checks
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return .fileMissing }
        guard fm.isReadableFile(atPath: url.path) else { return .notReadable }
        let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
        if let size, size == 0 { return .emptyFile }
        guard FormatCatalog.isVideo(url) else { return .unsupportedExtension }
        return nil
    }

    /// impl: MEDIA-002 rule 8 — a failure never leaves a half-open state.
    /// impl: MEDIA-002 rule 9 — `timedOut`/`index` let a timeout-sourced
    /// failure share every bit of this logic with an ordinary one; `index` is
    /// needed because a timeout fires long after `loadingIndex` was cleared.
    private func fail(_ failure: MediaFailure, _ url: URL, timedOut: Bool = false, index: Int? = nil) {
        openTimeout.disarm()
        log(.mediaOpenFailed, .error, [
            "reason": failure.reason,
            "redactedName": PathRedactor.redact(url),
            "timedOut": timedOut,
        ])
        state.transition(to: .idle)
        onFailure?(failure, url)

        // impl: LIST-001 rule 8 — a broken item is skipped, not fatal. The
        // index is cleared first: `skipFailed` loads the next item, which sets
        // its own, and a failure there must not re-mark this row.
        let queueIndex = index ?? loadingIndex
        if let queueIndex, queueIndex >= 0 {
            if index == nil { loadingIndex = nil }
            advancer?.skipFailed(at: queueIndex)
        }
    }

    /// impl: MEDIA-002 rule 9 — the 15 s watchdog's own entry point into the
    /// shared failure path.
    private func failFromTimeout(url: URL, index: Int) {
        fail(.decodeFailed, url, timedOut: true, index: index)
    }

    /// impl: MEDIA-001 rule 7 — released when the item leaves.
    private func releaseScopedAccess() {
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
    }

    /// Called by AppDelegate.applicationWillTerminate so no scope leaks.
    func shutdown() { releaseScopedAccess() }
}
