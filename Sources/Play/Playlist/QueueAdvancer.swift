// impl: LIST-001 rules 5-8 — what plays next, and when.
//
// Every move between items goes through `play(at:reason:)`, so there is exactly
// one place that marks an item playing, logs the move, and asks for the load.
// Auto-advance, ⌘], ⌘[ and skip-on-failure differ only in how they choose the
// index.

import Foundation

@MainActor
final class QueueAdvancer {
    /// impl: LIST-001 rule 6 — the near-universal "previous or restart" split.
    nonisolated static let restartThresholdMs = 3_000

    private let queue: Queue
    private let state: PlaybackState
    private let seeker: SeekController

    /// The one way an item is actually loaded. Set by AppDelegate to
    /// `FileOpener.load(item:index:)` — a closure rather than a stored
    /// reference so the opener and the advancer do not retain each other.
    var load: ((QueueItem, Int) -> Void)?

    /// impl: LIST-001 rule 8 — set by AppDelegate; one summary banner when the
    /// whole queue turned out to be unplayable.
    var onAllItemsFailed: (() -> Void)?

    init(queue: Queue, state: PlaybackState, seeker: SeekController) {
        self.queue = queue
        self.state = state
        self.seeker = seeker
    }

    // MARK: - Starting

    /// impl: LIST-001 rule 3 — called by FileOpener right after the queue is
    /// replaced. Deliberately does not log `playlist.advanced`: opening files is
    /// not an advance, and LIST-001-H1 counts exactly two advances for three
    /// items.
    func start() {
        guard let first = queue.nextPending(after: nil) else { return }
        play(at: first, reason: nil)
    }

    // MARK: - Advancing

    /// impl: LIST-001 rule 5 — called only by PlaybackState on `EndReached`,
    /// after it has already transitioned to `ended`. If nothing follows, the
    /// `ended` state stands.
    func advanceAutomatically() {
        guard let next = queue.nextPending(after: queue.currentIndex) else {
            log(.playlistExhausted, .info, ["count": queue.items.count])
            return
        }
        play(at: next, reason: "auto")
    }

    /// impl: CTRL-004 rule 8 — the same preconditions `next()` and
    /// `previousOrRestart()` apply, asked without performing them, so a menu
    /// item can be greyed rather than clicked into a logged refusal. They read
    /// the queue and nothing else, which keeps `Queue` owned here.
    var canGoNext: Bool { queue.nextPending(after: queue.currentIndex) != nil }

    /// Previous is available whenever there is an item to restart — rule 6 makes
    /// it "previous *or* restart", so it is not limited to a multi-item queue.
    var canGoPrevious: Bool {
        queue.currentIndex != nil || queue.previousIndex(before: queue.currentIndex) != nil
    }

    /// impl: LIST-002 rule 3 / LIST-001 rule 11 — a one-item queue has no panel
    /// and nothing to shuffle.
    var hasQueue: Bool { queue.hasMultipleItems }

    /// impl: LIST-001 rules 6-7 — ⌘] and `play.hud.nextButton`. Never wraps.
    /// Called by AppCommands and HUDView.
    @discardableResult
    func next() -> Bool {
        guard let next = queue.nextPending(after: queue.currentIndex) else {
            log(.playlistAdvanceIgnored, .info, ["reason": "atEnd"])
            return false
        }
        play(at: next, reason: "next")
        return true
    }

    /// impl: LIST-001 rule 6 — ⌘[ and `play.hud.previousButton`. Within the
    /// first 3 s it goes back an item; after that it restarts the current one.
    /// Called by AppCommands and HUDView.
    @discardableResult
    func previousOrRestart(element: String) -> Bool {
        if state.positionMs >= Self.restartThresholdMs, queue.currentIndex != nil {
            log(.playlistRestartedCurrent, .info, [
                "index": queue.currentIndex ?? -1, "positionMs": state.positionMs,
            ])
            seeker.seek(toMs: 0, element: element)
            return true
        }
        guard let previous = queue.previousIndex(before: queue.currentIndex) else {
            log(.playlistAdvanceIgnored, .info, ["reason": "atStart"])
            return false
        }
        play(at: previous, reason: "previous")
        return true
    }

    /// impl: LIST-002 rule 8 — a row click jumps straight to that item.
    /// Called only by QueueOverlayView.
    func jump(to index: Int) {
        guard queue.items.indices.contains(index) else { return }
        log(.playlistRowClicked, .info, ["index": index])
        play(at: index, reason: "row")
    }

    // MARK: - Failure

    /// impl: LIST-001 rule 8 — a broken item is marked, skipped, and the next
    /// one is attempted; only a queue that fails *entirely* is reported once.
    /// Called only by FileOpener's failure path.
    func skipFailed(at index: Int) {
        queue.markFailed(index)
        if let next = queue.nextPending(after: index) {
            play(at: next, reason: "auto")
            return
        }
        log(.playlistExhausted, .info, ["count": queue.items.count])
        if !queue.items.isEmpty, queue.items.allSatisfy({ $0.status == .failed }) {
            onAllItemsFailed?()
        }
    }

    /// impl: LIST-002 rule 10 — removing the item that is playing advances to
    /// what follows it; removing the last one empties the queue.
    /// Called only by QueueOverlayView.
    func currentItemRemoved(at index: Int) {
        guard let next = queue.nextPending(after: index - 1) else {
            log(.playlistExhausted, .info, ["count": queue.items.count])
            return
        }
        play(at: next, reason: "auto")
    }

    // MARK: - The one move

    private func play(at index: Int, reason: String?) {
        guard queue.items.indices.contains(index) else { return }
        if let reason {
            log(.playlistAdvanced, .info, [
                "fromIndex": queue.currentIndex ?? -1, "toIndex": index, "reason": reason,
            ])
        }
        let item = queue.items[index]
        queue.markPlaying(index)
        load?(item, index)
    }
}
