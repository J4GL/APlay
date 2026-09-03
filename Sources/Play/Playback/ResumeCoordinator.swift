// impl: PLAY-004 rules 5-9 — orchestrates every save/offer/dismiss/clear call.
//
// PlaybackState polls nothing and knows no file identity by design (its own
// header comment says so); this is the small, single-responsibility
// coordinator — the same shape as TransportController/SeekController/
// AutoHideController — that owns the 5 s ticker and the store, so neither
// PlaybackState nor FileOpener has to grow persistence concerns of its own.

import Foundation
import PlayA11y

@MainActor
final class ResumeCoordinator {
    private let store: ResumeStore
    private let state: PlaybackState
    private let seeker: SeekController

    private var ticker: Timer?
    private var offeredMrlHashes: Set<String> = []
    /// impl: PLAY-004 rule 8 — suppresses the seek `handleAccepted` itself
    /// issues from also being logged as a `dismissal: "seek"`.
    private var isAccepting = false

    /// Set by AppDelegate to `{ [weak opener] in opener?.currentMrlHash }` —
    /// the item currently loaded, independent of `Queue` (which already
    /// points at the *incoming* item by the time a media change reaches here).
    var currentMrlHash: (() -> String?)?

    /// impl: PLAY-004 rule 7 — set by AppDelegate to `ResumeToast.show`.
    var onOffer: ((ResumeRecord) -> Void)?
    /// impl: PLAY-004 rule 8 — a dismissal this coordinator itself decided
    /// (seek, media change); set by AppDelegate to `ResumeToast.dismiss(reason:)`.
    var onDismissRequested: ((String) -> Void)?
    /// impl: PLAY-004 rule 7 — acceptance hides the toast without logging a
    /// dismissal (acceptance is its own event, rule 11); set by AppDelegate
    /// to `ResumeToast.hideForAcceptance`.
    var onAccepted: (() -> Void)?

    init(store: ResumeStore, state: PlaybackState, seeker: SeekController) {
        self.store = store
        self.state = state
        self.seeker = seeker
    }

    // MARK: - Saving (rule 5)

    /// impl: PLAY-004 rule 5 — the ticker while playing, `pause()`, and
    /// termination all save the item currently loaded.
    func saveCurrent(reason: String) {
        guard let mrlHash = currentMrlHash?() else { return }
        store.save(mrlHash: mrlHash, positionMs: state.positionMs, lengthMs: state.lengthMs)
    }

    /// impl: PLAY-004 rule 5 — the *outgoing* item's position, captured by
    /// FileOpener before PlaybackState resets to the incoming item.
    func saveOnMediaChange(mrlHash: String, positionMs: Int, lengthMs: Int) {
        store.save(mrlHash: mrlHash, positionMs: positionMs, lengthMs: lengthMs)
    }

    /// impl: PLAY-001 rule 5 wiring — starts/stops the 5 s ticker on
    /// playing↔not-playing edges. Called via `PlaybackState.onPlayingChanged`.
    func setTicking(_ isPlaying: Bool) {
        ticker?.invalidate()
        ticker = nil
        guard isPlaying else { return }
        ticker = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveCurrent(reason: "ticker") }
        }
    }

    // MARK: - Offering (rule 7)

    /// impl: PLAY-004 rule 7 — called by FileOpener once per media, the first
    /// time its length is known. Offers at most once per file per session.
    func considerOffering(mrlHash: String?, lengthMs: Int) {
        guard let mrlHash, !offeredMrlHashes.contains(mrlHash) else { return }
        guard let record = store.record(for: mrlHash, currentLengthMs: lengthMs) else { return }
        offeredMrlHashes.insert(mrlHash)
        log(.playbackResumeOffered, .info, ["mrlHash": mrlHash, "positionMs": record.positionMs])
        onOffer?(record)
    }

    /// impl: PLAY-004 rule 8 — dismisses any visible toast on a media change;
    /// the record itself survives (only `handleEnded` clears it).
    func mediaWillChange() {
        onDismissRequested?("mediaChange")
    }

    /// impl: PLAY-004 rule 8 — "any seek" dismisses the toast, except the
    /// seek `handleAccepted` performs on its own behalf.
    func noteSeekOccurred() {
        guard !isAccepting else { return }
        onDismissRequested?("seek")
    }

    // MARK: - Toast outcomes (rules 7-8, 11)

    /// impl: PLAY-004 rule 7 — the "Resume" action: seek there and log.
    func handleAccepted(record: ResumeRecord) {
        isAccepting = true
        seeker.seek(toMs: record.positionMs, element: A11yID.toastResumeAction.rawValue)
        isAccepting = false
        log(.playbackResumeAccepted, .info, ["toMs": record.positionMs])
        onAccepted?()
    }

    /// impl: PLAY-004 rule 8 — logs whichever of the four reasons dismissed
    /// the toast; the store is untouched either way.
    func handleDismissed(reason: String) {
        log(.playbackResumeDismissed, .info, ["dismissal": reason])
    }

    // MARK: - Ended (rule 5)

    /// impl: PLAY-004 rule 5 — called only on `ended`; a finished film starts
    /// at the beginning next time.
    func handleEnded(mrlHash: String?) {
        guard let mrlHash else { return }
        store.clear(mrlHash: mrlHash)
    }
}
