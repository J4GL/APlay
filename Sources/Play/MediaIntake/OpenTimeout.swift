// impl: MEDIA-002 rule 9 — the 15 s `.opening` watchdog.
//
// `FileOpener.loadingIndex` is cleared right after `player.play()` succeeds
// (a later, unrelated failure must not be attributed to it), well before
// `.opening` can be confirmed to be progressing 15 s later — so the index this
// fires against is captured at arm-time, not read back from FileOpener.

import Foundation

@MainActor
final class OpenTimeout {
    private static let duration: TimeInterval = 15

    private let state: PlaybackState
    private var work: DispatchWorkItem?

    /// Set by FileOpener; called only when a countdown armed for `.opening`
    /// reaches 15 s while the state is still `.opening`.
    var onTimeout: ((URL, Int) -> Void)?

    init(state: PlaybackState) {
        self.state = state
    }

    func arm(url: URL, index: Int) {
        disarm()
        let item = DispatchWorkItem { [weak self] in self?.fire(url: url, index: index) }
        work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.duration, execute: item)
    }

    func disarm() {
        work?.cancel()
        work = nil
    }

    /// impl: MEDIA-002 rule 9 — self-correcting: a timer that outlived its item
    /// (already resolved, success or a faster failure) is a silent no-op.
    private func fire(url: URL, index: Int) {
        work = nil
        guard state.status == .opening else { return }
        onTimeout?(url, index)
    }
}
