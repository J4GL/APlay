// impl: PLAY-001 rule 2 — the transition table, asserted directly.
//
// PLAY-001-S3 proves the runtime refuses an illegal transition through the
// event path; this file proves the table itself, which is cheap enough to run
// on every build.

import XCTest
@testable import Play

final class PlaybackStateMachineTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // impl: rule 7 of AGENTS.md — every test carries an explicit timeout.
        executionTimeAllowance = 10
    }

    @MainActor
    func testLegalTransitionsAreAccepted() {
        let legal: [(PlaybackState.Status, PlaybackState.Status)] = [
            (.idle, .opening), (.opening, .playing), (.opening, .failed(.decodeFailed)),
            (.playing, .paused), (.paused, .playing), (.playing, .ended),
            (.playing, .failed(.decodeFailed)), (.paused, .ended),
            (.paused, .failed(.decodeFailed)), (.ended, .opening),
            (.failed(.decodeFailed), .opening),
            (.playing, .idle), (.paused, .idle), (.ended, .idle),
            // A different file, loaded while one is already running: ⌘], ⌘[, a
            // queue row, a drop, ⌘O. Refusing these meant the per-media reset
            // was skipped on every manual advance.
            (.playing, .opening), (.paused, .opening),
        ]
        for (from, to) in legal {
            XCTAssertTrue(PlaybackState.isLegal(from: from, to: to),
                          "\(from.name) -> \(to.name) must be legal (PLAY-001 rule 2)")
        }
    }

    @MainActor
    func testIllegalTransitionsAreRefused() {
        let illegal: [(PlaybackState.Status, PlaybackState.Status)] = [
            (.idle, .playing), (.idle, .paused), (.idle, .ended),
            (.opening, .paused), (.opening, .ended),
            (.ended, .playing), (.ended, .paused),
            (.failed(.decodeFailed), .playing),
        ]
        for (from, to) in illegal {
            XCTAssertFalse(PlaybackState.isLegal(from: from, to: to),
                           "\(from.name) -> \(to.name) must be refused (PLAY-001 rule 2)")
        }
    }

    /// impl: PLAY-001-S3 — an illegal transition is ignored, not applied.
    @MainActor
    func testIllegalTransitionLeavesStatusUnchanged() {
        let state = PlaybackState()
        XCTAssertEqual(state.status, .idle)
        state.transition(to: .paused)
        XCTAssertEqual(state.status, .idle, "status must survive an illegal transition")
    }

    /// impl: MEDIA-002 rule 6 — every case has a distinct message.
    func testEveryFailureCaseHasADistinctMessage() {
        let all: [MediaFailure] = [
            .fileMissing, .notReadable, .emptyFile, .unsupportedExtension,
            .noPlayableTrack, .decodeFailed, .drmProtected,
        ]
        let messages = Set(all.map(\.message))
        XCTAssertEqual(messages.count, all.count, "no two failures may share a message")
    }
}
