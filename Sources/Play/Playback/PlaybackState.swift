// impl: PLAY-001 rules 1-3, 8-10 — the single source of truth for playback.
//
// Driven only by libvlc events (VLC-002 rule 8). Nothing here polls, and no
// call site sets status optimistically.

import AppKit
import Foundation

@MainActor
final class PlaybackState {
    /// impl: PLAY-001 rule 1 — exactly six cases, stored nowhere else.
    enum Status: Equatable {
        case idle, opening, playing, paused, ended
        case failed(MediaFailure)

        var name: String {
            switch self {
            case .idle: "idle"; case .opening: "opening"; case .playing: "playing"
            case .paused: "paused"; case .ended: "ended"; case .failed: "failed"
            }
        }
    }

    private(set) var status: Status = .idle
    private(set) var positionMs: Int = 0
    private(set) var lengthMs: Int = 0
    private(set) var isSeekable = false
    private(set) var hasVout = false

    /// Observers redraw on any change. Set by AppDelegate (HUD) and by the
    /// window shell; there is no other subscription mechanism.
    var onChange: (() -> Void)?

    /// impl: TRACK-001 rule 1 / TRACK-003 rule 1 — the ES list is rebuilt from
    /// events, never snapshotted. Set by AppDelegate to TrackCatalog.rebuild.
    var onTracksChanged: (() -> Void)?

    /// impl: TRACK-001 rule 6 · TRACK-002 rule 5 · TRACK-003 rule 9 — every
    /// per-media selection resets here, at one well-defined moment, rather than
    /// each controller racing the parser on its own.
    var onMediaChanged: (() -> Void)?

    /// impl: WIN-003 rule 1 — set by AppDelegate to `AspectRatioLock
    /// .videoDidAppear`. Fired only when a vout *appears*, which is the earliest
    /// moment libvlc knows the video's dimensions.
    var onVoutChanged: (() -> Void)?

    /// impl: LIST-001 rule 5 — set by AppDelegate to `QueueAdvancer
    /// .advanceAutomatically`. `EndReached` is the only thing that calls it.
    var onEndReached: (() -> Void)?

    /// impl: MEDIA-002 rule 6/7 — set by AppDelegate; libvlc's own async decode
    /// error for the *currently loaded* media. Fired after the transition to
    /// `.idle`, mirroring `onEndReached`'s ordering.
    var onEncounteredError: (() -> Void)?

    /// impl: PLAY-001 rule 10 — the sleep-prevention token, held only while playing.
    private var sleepToken: NSObjectProtocol?

    // MARK: - Event intake

    /// impl: VLC-002 rule 8 — the only consumer of VLCEvent.
    /// Called only by MediaPlayer's bridge wiring.
    func apply(_ event: VLCEvent) {
        switch event.kind {
        case .opening:          transition(to: .opening)
        case .playing:          transition(to: .playing)
        case .paused:           transition(to: .paused)
        case .stopped:          transition(to: .idle)
        case .endReached:       handleEndReached()
        case .encounteredError:
            // impl: MEDIA-002 rule 8 — the same target FileOpener.fail uses, so
            // this path is never left in `.opening` either.
            transition(to: .idle)
            onEncounteredError?()
        case .timeChanged(let ms):
            positionMs = ms
            onChange?()
        case .lengthChanged(let ms):
            lengthMs = ms
            onChange?()
        case .seekableChanged(let s):
            isSeekable = s
            onChange?()
        case .vout(let count):
            hasVout = count > 0
            log(.engineVout, .info, ["count": count])
            // impl: WIN-003 rule 1 — only the appearance of a vout carries new
            // dimensions; its disappearance carries none.
            if hasVout { onVoutChanged?() }
            onChange?()
        case .esAdded, .esDeleted:
            // impl: TRACK-001 rule 1 / TRACK-003 rule 1 — rebuilt on every ES
            // event, which is what makes the menu correct on containers that
            // declare their subtitle tracks after playback has started.
            onTracksChanged?()
        }
    }

    /// impl: PLAY-001 rule 8 · LIST-001 rule 5 — `ended` is entered first and
    /// then the queue is asked for a successor, so a queue that has one moves
    /// `ended → opening` (a legal transition) and a queue that does not simply
    /// stays `ended`.
    private func handleEndReached() {
        log(.playbackEnded, .info, ["positionMs": positionMs, "lengthMs": lengthMs])
        transition(to: .ended)
        onEndReached?()
    }

    // MARK: - The state machine

    /// impl: PLAY-002 rule 3 — a seek publishes its own target rather than
    /// waiting for a time event, because libvlc emits none while **paused**: the
    /// seek happened, and only the bar disagreed, snapping back to where it was.
    /// The value is the one already handed to libvlc, and `status` is untouched,
    /// so PLAY-001 rule 3 is not weakened. Called only by `SeekController`.
    func applySeekedPosition(_ ms: Int) {
        guard ms != positionMs else { return }
        positionMs = ms
        onChange?()
    }

    /// impl: PLAY-001 rule 2 — legal transitions only; an illegal one is logged
    /// and *ignored*, so one bad event cannot corrupt the machine.
    func transition(to next: Status) {
        guard status != next else { return }
        guard Self.isLegal(from: status, to: next) else {
            log(.playbackStateIllegal, .error, ["from": status.name, "to": next.name])
            return
        }
        let from = status
        status = next
        // impl: TRACK-001 rule 6 · TRACK-002 rule 5 · TRACK-003 rule 9 —
        // `opening` is the one transition that means "a different file".
        if next == .opening {
            // impl: LIST-001 rules 6, 9 — position and length are per-media and
            // must not survive an advance. Observed: item B inherited item A's
            // 4521 ms, so the very first ⌘[ after an auto-advance took rule 6's
            // "past 3 s" branch and restarted B instead of going back to A.
            positionMs = 0
            lengthMs = 0
            onMediaChanged?()
        }
        updateSleepAssertion()
        log(.playbackStateChanged, .info, [
            "from": from.name, "to": next.name, "positionMs": positionMs,
        ])
        log(.engineStateChanged, .debug, [
            "from": from.name, "to": next.name,
            "positionMs": positionMs, "lengthMs": lengthMs,
        ])
        onChange?()
    }

    /// impl: PLAY-001 rule 2 — the transition table, transcribed exactly.
    static func isLegal(from: Status, to: Status) -> Bool {
        if case .idle = to { return true }              // any → idle
        switch (from, to) {
        // `opening` means "a different file is being loaded", which can happen
        // from any state: ⌘] / ⌘[ / a queue row / a drop / ⌘O, while something
        // is already running. Allowing it only from idle/ended/failed described
        // auto-advance and nothing else — and because an illegal transition is
        // *ignored*, a manual advance from `playing` silently skipped the
        // per-media reset `onMediaChanged` drives, until libvlc's own `stopped`
        // rescued it a beat later.
        case (.idle, .opening), (.ended, .opening), (.failed, .opening),
             (.playing, .opening), (.paused, .opening):                     return true
        case (.opening, .playing), (.opening, .failed):                     return true
        case (.playing, .paused), (.paused, .playing):                      return true
        case (.playing, .ended), (.playing, .failed):                       return true
        case (.paused, .ended), (.paused, .failed):                         return true
        default:                                                            return false
        }
    }

    // MARK: - Sleep prevention

    /// impl: PLAY-001 rule 10 — prevented while `playing` and only while
    /// `playing`; every acquisition is matched by exactly one release.
    private func updateSleepAssertion() {
        let shouldHold = status == .playing
        if shouldHold, sleepToken == nil {
            sleepToken = ProcessInfo.processInfo.beginActivity(
                options: [.idleDisplaySleepDisabled, .userInitiated],
                reason: "Video playback"
            )
            log(.playbackSleepPrevented, .info, ["status": status.name])
        } else if !shouldHold, let token = sleepToken {
            ProcessInfo.processInfo.endActivity(token)
            sleepToken = nil
            log(.playbackSleepReleased, .info, ["status": status.name])
        }
    }

    /// impl: PLAY-001 rule 10 — termination must release the token too, or the
    /// user's display stays awake. Called by AppDelegate.applicationWillTerminate.
    func releaseSleepAssertionForTermination() {
        if let token = sleepToken {
            ProcessInfo.processInfo.endActivity(token)
            sleepToken = nil
            log(.playbackSleepReleased, .info, ["status": "terminating"])
        }
    }
}
