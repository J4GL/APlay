// impl: LIST-001 rules 1-4, 11 — the ordered list of what is going to play.
//
// Session state only (rule 2). Play has no library and no history view, so a
// queue that survived a relaunch would be invisible state the user cannot see
// or clear.

import Foundation

/// impl: LIST-001 rule 1
enum QueueItemStatus: String, Sendable {
    case pending, playing, played, failed
}

struct QueueItem: Identifiable, Sendable {
    let id = UUID()
    let url: URL
    let mrlHash: String
    let displayName: String
    var status: QueueItemStatus = .pending

    init(url: URL) {
        self.url = url
        self.mrlHash = PathRedactor.mrlHash(url)
        self.displayName = url.deletingPathExtension().lastPathComponent
    }
}

@MainActor
final class Queue {
    private(set) var items: [QueueItem] = []

    /// impl: LIST-001 rule 1 — exactly one item may be `playing`.
    private(set) var currentIndex: Int?

    /// Redraws the HUD's queue controls and the LIST-002 panel. Set by AppDelegate.
    var onChange: (() -> Void)?

    var current: QueueItem? {
        guard let currentIndex, items.indices.contains(currentIndex) else { return nil }
        return items[currentIndex]
    }

    /// impl: LIST-001 rule 12 — with one item there is no queue to control, and
    /// the next/previous/queue buttons are hidden entirely.
    var hasMultipleItems: Bool { items.count > 1 }

    // MARK: - Building

    /// impl: LIST-001 rule 3 — opening files replaces the queue. Called only by
    /// FileOpener, with the URLs already expanded and name-ordered.
    func replace(with urls: [URL], source: String) {
        items = urls.map(QueueItem.init)
        currentIndex = nil
        log(.playlistBuilt, .info, ["count": items.count, "source": source])
        onChange?()
    }

    /// impl: LIST-001 rule 4 — an ⌥-drop appends, so a second batch can be added
    /// without losing the first. Called only by FileOpener.
    func append(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        items.append(contentsOf: urls.map(QueueItem.init))
        log(.playlistAppended, .info, ["count": urls.count, "total": items.count])
        onChange?()
    }

    // MARK: - Status

    /// impl: LIST-001 rule 1 — moving the cursor is the only way an item becomes
    /// `playing`, which is what keeps "exactly one" true by construction.
    func markPlaying(_ index: Int) {
        guard items.indices.contains(index) else { return }
        for position in items.indices where items[position].status == .playing {
            items[position].status = .played
        }
        items[index].status = .playing
        currentIndex = index
        onChange?()
    }

    func markFailed(_ index: Int) {
        guard items.indices.contains(index) else { return }
        items[index].status = .failed
        log(.playlistItemFailed, .info, ["index": index])
        onChange?()
    }

    /// The next `pending` item after `index`, or nil at the end. Rule 7's
    /// refusal to wrap lives here: there is no modulo anywhere in this file.
    func nextPending(after index: Int?) -> Int? {
        let start = (index ?? -1) + 1
        guard start < items.count else { return nil }
        return (start..<items.count).first { items[$0].status != .failed }
    }

    func previousIndex(before index: Int?) -> Int? {
        guard let index, index > 0 else { return nil }
        return (0..<index).last { items[$0].status != .failed }
    }

    // MARK: - Editing

    /// impl: LIST-002 rule 10 — removing the current item is the caller's cue to
    /// advance; this only edits the list.
    @discardableResult
    func remove(at index: Int) -> Bool {
        guard items.indices.contains(index) else { return false }
        let wasCurrent = index == currentIndex
        items.remove(at: index)
        if let current = currentIndex {
            if wasCurrent { currentIndex = nil }
            else if index < current { currentIndex = current - 1 }
        }
        log(.playlistRemoved, .info, ["index": index, "wasCurrent": wasCurrent])
        onChange?()
        return wasCurrent
    }

    /// impl: LIST-002 rule 9 — legality lives in QueueReorderPolicy, so the
    /// insertion line and the move are decided by the same function.
    @discardableResult
    func move(from: Int, to: Int) -> Bool {
        guard QueueReorderPolicy.canMove(from: from, to: to, in: self) else {
            log(.playlistReorderRejected, .info, ["reason": "playedOrCurrent"])
            return false
        }
        let item = items.remove(at: from)
        items.insert(item, at: to)
        log(.playlistReordered, .info, ["fromIndex": from, "toIndex": to])
        onChange?()
        return true
    }

    /// impl: LIST-001 rule 11 — only the `pending` tail is shuffled, so what was
    /// just watched cannot come back round.
    func shufflePending() {
        let boundary = (currentIndex ?? -1) + 1
        guard boundary < items.count else { return }
        var tail = Array(items[boundary...])
        tail.shuffle()
        items.replaceSubrange(boundary..., with: tail)
        log(.playlistShuffled, .info, ["pendingCount": tail.count])
        onChange?()
    }
}
