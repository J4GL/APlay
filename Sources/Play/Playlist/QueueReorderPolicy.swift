// impl: LIST-002 rule 9 — one decision point for "may this move?".
//
// Called by the drag-validation callback (which draws the insertion line) and
// by the drop handler (which performs the move). One function so the line the
// user sees and the move they get can never disagree.

import Foundation

enum QueueReorderPolicy {
    /// impl: LIST-002 rule 9 — `played` rows and the current row cannot move,
    /// and nothing may be dropped above the current row. The past is history:
    /// the only forward question is what comes next.
    ///
    /// `boundary` is the current index — everything at or before it is fixed.
    /// `nil` means nothing has played yet, so the whole list is free.
    nonisolated static func canMove(from: Int, to: Int, boundary: Int?) -> Bool {
        guard from != to else { return false }
        guard let boundary else { return true }
        return from > boundary && to > boundary
    }

    @MainActor
    static func canMove(from: Int, to: Int, in queue: Queue) -> Bool {
        guard queue.items.indices.contains(from), queue.items.indices.contains(to) else {
            return false
        }
        return canMove(from: from, to: to, boundary: queue.currentIndex)
    }
}
