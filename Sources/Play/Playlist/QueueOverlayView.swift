// impl: LIST-002 — the queue panel: what is queued, and the four things you can
// do to it (jump, reorder, remove, shuffle).
//
// It shows the model and asks controllers to change it. Every mutation goes to
// `Queue` or `QueueAdvancer`; nothing here touches libvlc.

import AppKit
import PlayA11y

/// impl: LIST-002 rule 13 — every open and close says which input caused it.
enum PanelTrigger: String, Sendable {
    case keyboard, button, menu, escape, outsideClick, queueShrank
}

@MainActor
final class QueueOverlayView: NSView {
    /// impl: LIST-002 rule 1 — `min(320 pt, 40 % of window width)`.
    private static let maxWidth: CGFloat = 320
    private static let widthFraction: CGFloat = 0.4
    private static let slideDuration: TimeInterval = 0.2

    private let queue: Queue
    private let advancer: QueueAdvancer

    private let rowsStack = NSStackView()
    private let scrollView = NSScrollView()
    /// impl: LIST-002 rule 9 — drawn only where a move is actually legal.
    private let insertionLine = NSView()

    private var widthConstraint: NSLayoutConstraint!
    private var trailingConstraint: NSLayoutConstraint!

    private(set) var isOpen = false
    /// impl: LIST-002 rule 10 — ⌫ needs a target, and Play has no other notion
    /// of selection, so the last clicked row is it.
    private(set) var selectedIndex: Int?

    /// impl: WIN-001 rule 9.4 — the panel is a control surface in its entirety
    /// and never moves the window. This was true before only by `NSView`'s
    /// default, which is not a decision anyone made; a drag between two rows
    /// belongs to the panel, not to the desktop.
    override var mouseDownCanMoveWindow: Bool { false }

    private var dragSourceIndex: Int?
    private var dragTargetIndex: Int?

    /// impl: CTRL-001 rule 5 / LIST-002 rule 4 — paired, set by AppDelegate.
    var onSuppress: ((HUDSuppression) -> Void)?
    var onRelease: ((HUDSuppression) -> Void)?

    /// impl: LIST-002 rule 12 — set by AppDelegate to FileOpener's append route.
    var onFilesDropped: (([URL]) -> Void)?

    init(queue: Queue, advancer: QueueAdvancer) {
        self.queue = queue
        self.advancer = advancer
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        isHidden = true

        // rule 1 — translucent dark material, over the video, never beside it.
        let material = NSVisualEffectView()
        material.material = .hudWindow
        material.blendingMode = .withinWindow
        material.state = .active
        material.translatesAutoresizingMaskIntoConstraints = false
        addSubview(material)

        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 2
        rowsStack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        rowsStack.translatesAutoresizingMaskIntoConstraints = false

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(rowsStack)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.documentView = document
        addSubview(scrollView)

        insertionLine.wantsLayer = true
        insertionLine.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        insertionLine.isHidden = true
        addSubview(insertionLine)

        NSLayoutConstraint.activate([
            material.leadingAnchor.constraint(equalTo: leadingAnchor),
            material.trailingAnchor.constraint(equalTo: trailingAnchor),
            material.topAnchor.constraint(equalTo: topAnchor),
            material.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor, constant: 28),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            document.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
            rowsStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            rowsStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            rowsStack.topAnchor.constraint(equalTo: document.topAnchor),
            rowsStack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])

        setAccessibilityIdentifier(A11yID.queuePanel.rawValue)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Queue")

        // impl: LIST-002 rule 12 — files dropped on the panel append.
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Play builds no nibs") }

    /// Called once by AppDelegate after the panel is added to the content root.
    func installConstraints(in parent: NSView) {
        widthConstraint = widthAnchor.constraint(equalToConstant: Self.maxWidth)
        trailingConstraint = trailingAnchor.constraint(equalTo: parent.trailingAnchor,
                                                       constant: Self.maxWidth)
        NSLayoutConstraint.activate([
            topAnchor.constraint(equalTo: parent.topAnchor),
            bottomAnchor.constraint(equalTo: parent.bottomAnchor),
            widthConstraint, trailingConstraint,
        ])
    }

    override func layout() {
        super.layout()
        // rule 1 — recomputed on every window resize, not fixed at build time.
        let available = superview?.bounds.width ?? Self.maxWidth
        let target = min(Self.maxWidth, available * Self.widthFraction)
        guard abs(widthConstraint.constant - target) > 0.5 else { return }
        widthConstraint.constant = target
        if !isOpen { trailingConstraint.constant = target }
    }

    // MARK: - Open and close

    /// impl: LIST-002 rule 2 — ⌘L, the queue button, Esc, and a click on the
    /// video all land here. Called by AppCommands and HUDView.
    @discardableResult
    func toggle(trigger: PanelTrigger) -> Bool {
        isOpen ? close(trigger: trigger) : open(trigger: trigger)
    }

    /// impl: LIST-002 rule 3 — a panel for a one-item queue is not a smaller
    /// panel, it is no panel: it never opens, and never enters the hierarchy.
    @discardableResult
    func open(trigger: PanelTrigger) -> Bool {
        guard !isOpen, queue.hasMultipleItems else { return false }
        isOpen = true
        isHidden = false
        rebuild()
        log(.playlistPanelOpened, .info, ["trigger": trigger.rawValue, "count": queue.items.count])
        // impl: LIST-002 rule 4 — a list that vanishes mid-scroll is unusable.
        onSuppress?(.queuePanelOpen)
        slide(to: 0)
        return true
    }

    @discardableResult
    func close(trigger: PanelTrigger) -> Bool {
        guard isOpen else { return false }
        isOpen = false
        selectedIndex = nil
        log(.playlistPanelClosed, .info, ["trigger": trigger.rawValue])
        onRelease?(.queuePanelOpen)
        slide(to: widthConstraint.constant, hideWhenDone: true)
        return true
    }

    private func slide(to constant: CGFloat, hideWhenDone: Bool = false) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.slideDuration
            trailingConstraint.animator().constant = constant
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // CTRL-003 rule 7 — genuinely out of the hierarchy when closed,
                // not alpha-zero, or `waitForNonExistence` proves nothing.
                guard hideWhenDone, let self, !self.isOpen else { return }
                self.isHidden = true
            }
        }
    }

    // MARK: - Rows

    /// impl: LIST-002 rules 5-6 — rebuilt from the model on every change, so a
    /// row's glyph can never disagree with the item's status.
    /// Called by AppDelegate through `Queue.onChange`.
    func rebuild() {
        // rule 3 — the queue shrinking below two items takes the panel with it.
        if isOpen, !queue.hasMultipleItems {
            close(trigger: .queueShrank)
            return
        }
        guard isOpen else { return }

        rowsStack.arrangedSubviews.forEach {
            rowsStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        for (index, item) in queue.items.enumerated() {
            let row = QueueRowView(index: index, item: item,
                                   isCurrent: index == queue.currentIndex,
                                   isSelected: index == selectedIndex)
            row.onClick = { [weak self] in self?.rowClicked(index) }
            row.onRemove = { [weak self] in self?.remove(at: index) }
            row.onDragStart = { [weak self] event in self?.dragBegan(from: index, event: event) }
            row.onDragUpdate = { [weak self] event in self?.dragMoved(event) }
            row.onDragEnd = { [weak self] event in self?.dragEnded(event) }
            rowsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor,
                                       constant: -16).isActive = true
        }
        layoutSubtreeIfNeeded()
        scrollCurrentIntoView()
    }

    /// impl: LIST-002 rule 6 — the current row is scrolled into view when the
    /// panel opens and on every advance.
    private func scrollCurrentIntoView() {
        guard let index = queue.currentIndex,
              rowsStack.arrangedSubviews.indices.contains(index) else { return }
        rowsStack.arrangedSubviews[index].scrollToVisible(
            rowsStack.arrangedSubviews[index].bounds)
    }

    /// impl: LIST-002 rule 8 — clicking a row plays it immediately.
    private func rowClicked(_ index: Int) {
        selectedIndex = index
        advancer.jump(to: index)
    }

    /// impl: LIST-002 rule 10 — removing the current item advances; removing the
    /// last one empties the queue.
    private func remove(at index: Int) {
        selectedIndex = nil
        let wasCurrent = queue.remove(at: index)
        if wasCurrent { advancer.currentItemRemoved(at: index) }
    }

    /// impl: LIST-002 rule 10 — ⌫ on the selected row. Called only by
    /// AppCommands, which owns every key in the app.
    @discardableResult
    func removeSelectedRow() -> Bool {
        guard isOpen, let index = selectedIndex, queue.items.indices.contains(index) else {
            return false
        }
        remove(at: index)
        return true
    }

    // MARK: - Reordering

    private func dragBegan(from index: Int, event: NSEvent) {
        dragSourceIndex = index
        dragMoved(event)
    }

    private func dragMoved(_ event: NSEvent) {
        guard let source = dragSourceIndex else { return }
        let target = rowIndex(at: event)
        dragTargetIndex = target
        // impl: LIST-002 rule 9 — the line is drawn from the same predicate the
        // drop obeys, so an illegal drag shows nothing at all.
        guard target != source,
              QueueReorderPolicy.canMove(from: source, to: target, in: queue) else {
            insertionLine.isHidden = true
            return
        }
        showInsertionLine(above: target)
    }

    private func dragEnded(_ event: NSEvent) {
        defer {
            dragSourceIndex = nil
            dragTargetIndex = nil
            insertionLine.isHidden = true
        }
        guard let source = dragSourceIndex, let target = dragTargetIndex,
              target != source else { return }
        // `move` logs the rejection itself when the policy refuses.
        queue.move(from: source, to: target)
    }

    /// The row under the pointer, clamped to the list — a drag released past the
    /// last row means "put it last", not "do nothing".
    private func rowIndex(at event: NSEvent) -> Int {
        let point = rowsStack.convert(event.locationInWindow, from: nil)
        for (index, row) in rowsStack.arrangedSubviews.enumerated()
        where row.frame.minY <= point.y && point.y <= row.frame.maxY {
            return index
        }
        let last = max(0, rowsStack.arrangedSubviews.count - 1)
        guard let first = rowsStack.arrangedSubviews.first else { return 0 }
        return point.y < first.frame.minY ? 0 : last
    }

    private func showInsertionLine(above index: Int) {
        guard rowsStack.arrangedSubviews.indices.contains(index) else { return }
        let row = rowsStack.arrangedSubviews[index]
        let frameInPanel = convert(row.frame, from: rowsStack)
        insertionLine.frame = NSRect(x: frameInPanel.minX, y: frameInPanel.maxY - 1,
                                     width: frameInPanel.width, height: 2)
        insertionLine.isHidden = false
    }

    // MARK: - File drops (rule 12)

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !Self.droppedURLs(sender).isEmpty else { return [] }
        // The line sits at the end of the list because the drop appends —
        // drawing it under the pointer would promise an insert-at-index that
        // LIST-001 rule 4 does not perform. See LIST-002's Notes.
        showInsertionLine(above: max(0, rowsStack.arrangedSubviews.count - 1))
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        insertionLine.isHidden = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        insertionLine.isHidden = true
        let urls = Self.droppedURLs(sender)
        guard !urls.isEmpty else { return false }
        onFilesDropped?(urls)
        return true
    }

    private static func droppedURLs(_ sender: NSDraggingInfo) -> [URL] {
        let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter(DropTarget.isAcceptable)
    }
}

/// The scroll view's document must be top-down, or the first queue item is at
/// the bottom of the panel.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
