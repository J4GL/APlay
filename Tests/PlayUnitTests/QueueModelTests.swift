// impl: LIST-001 rules 1, 7, 11 · LIST-002 rule 9 — the queue's pure decisions,
// tested without a window or a live libvlc.

import XCTest
@testable import Play

final class QueueModelTests: XCTestCase {
    /// impl: LIST-002 rule 9 — the single predicate both the insertion line and
    /// the drop obey. `boundary` is the current index; at or before it is the
    /// past, which does not move.
    func testReorderPolicyProtectsThePast() {
        XCTAssertFalse(QueueReorderPolicy.canMove(from: 0, to: 3, boundary: 2),
                       "a played row cannot move")
        XCTAssertFalse(QueueReorderPolicy.canMove(from: 2, to: 3, boundary: 2),
                       "the current row cannot move")
        XCTAssertFalse(QueueReorderPolicy.canMove(from: 3, to: 1, boundary: 2),
                       "nothing may be dropped above the current row")
        XCTAssertTrue(QueueReorderPolicy.canMove(from: 3, to: 4, boundary: 2),
                      "pending rows move freely")
        XCTAssertTrue(QueueReorderPolicy.canMove(from: 1, to: 0, boundary: nil),
                      "nothing has played yet, so the whole list is free")
        XCTAssertFalse(QueueReorderPolicy.canMove(from: 3, to: 3, boundary: nil),
                       "a row dropped on itself is not a move")
    }

    /// impl: LIST-001 rules 1, 7-8 — the cursor moves forward, never wraps, and
    /// steps over failed items.
    @MainActor
    func testAdvanceNeverWrapsAndSkipsFailedItems() {
        let queue = Queue()
        queue.replace(with: (0..<3).map { URL(fileURLWithPath: "/tmp/clip\($0).mp4") },
                      source: "test")

        XCTAssertEqual(queue.nextPending(after: nil), 0, "an untouched queue starts at 0")
        queue.markPlaying(0)
        XCTAssertEqual(queue.nextPending(after: 0), 1)
        queue.markFailed(1)
        XCTAssertEqual(queue.nextPending(after: 0), 2, "rule 8 — a failed item is stepped over")
        queue.markPlaying(2)
        XCTAssertNil(queue.nextPending(after: 2), "rule 7 — the end is the end; it does not wrap")
        XCTAssertEqual(queue.previousIndex(before: 2), 0,
                       "going back also steps over the failed item")
        XCTAssertNil(queue.previousIndex(before: 0))
    }

    /// impl: LIST-001 rule 1 — exactly one item may be `playing`.
    @MainActor
    func testOnlyOneItemIsEverPlaying() {
        let queue = Queue()
        queue.replace(with: (0..<3).map { URL(fileURLWithPath: "/tmp/clip\($0).mp4") },
                      source: "test")
        queue.markPlaying(0)
        queue.markPlaying(2)
        XCTAssertEqual(queue.items.filter { $0.status == .playing }.count, 1)
        XCTAssertEqual(queue.items[0].status, .played, "the outgoing item becomes played")
        XCTAssertEqual(queue.currentIndex, 2)
    }

    /// impl: LIST-001 rule 11 — shuffle touches the pending tail only, so what
    /// was just watched cannot come back round.
    @MainActor
    func testShuffleLeavesPlayedItemsAndTheCurrentItemInPlace() {
        let queue = Queue()
        queue.replace(with: (0..<20).map { URL(fileURLWithPath: "/tmp/clip\($0).mp4") },
                      source: "test")
        queue.markPlaying(2)
        let before = queue.items.map(\.displayName)

        queue.shufflePending()
        let after = queue.items.map(\.displayName)

        XCTAssertEqual(Array(after.prefix(3)), Array(before.prefix(3)),
                       "the played items and the current one keep their positions")
        XCTAssertEqual(Set(after), Set(before), "shuffling loses nothing")
        XCTAssertNotEqual(after, before,
                          "with 17 pending items an identical order is a 1-in-17! event")
    }

    /// impl: LIST-002 rule 10 — removal keeps the cursor pointing at the same
    /// item, which is what makes "removing the current item advances" a decision
    /// the caller can make rather than a guess.
    @MainActor
    func testRemovalKeepsTheCursorOnTheSameItem() {
        let queue = Queue()
        queue.replace(with: (0..<4).map { URL(fileURLWithPath: "/tmp/clip\($0).mp4") },
                      source: "test")
        queue.markPlaying(2)

        XCTAssertFalse(queue.remove(at: 0), "removing an earlier row is not removing the current")
        XCTAssertEqual(queue.currentIndex, 1, "the cursor followed its item")
        XCTAssertTrue(queue.remove(at: 1), "removing the current row reports it")
        XCTAssertNil(queue.currentIndex, "nothing is playing until the caller advances")
    }
}
