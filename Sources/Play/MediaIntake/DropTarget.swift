// impl: MEDIA-001 rules 2, 9-10, 12 — the drop route and the highlight's lifetime.
//
// The highlight is transient and easy to leak: every path out of a drag
// (`exited`, `ended`, a performed drop, a rejected drop) goes through
// `clearHighlight()`, because a highlight that survives the drag is the one
// failure a user actually notices.

import AppKit
import PlayA11y

@MainActor
final class DropTarget {
    private let opener: FileOpener
    private unowned let host: VideoHostView
    private var highlight: DropHighlightView?
    /// impl: MEDIA-001-S1 — one rejection log per drag session, not one per
    /// `draggingUpdated` callback.
    private var rejectionLogged = false

    init(opener: FileOpener, host: VideoHostView) {
        self.opener = opener
        self.host = host
    }

    /// impl: MEDIA-001 rule 10 — accepted only when the pasteboard carries at
    /// least one file URL Play can actually open.
    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let urls = Self.fileURLs(on: sender.draggingPasteboard)
        guard !urls.isEmpty, urls.contains(where: Self.isAcceptable) else {
            if !rejectionLogged {
                rejectionLogged = true
                log(.mediaOpenRejectedDrag, .info, [
                    "extensions": urls.map { $0.pathExtension.lowercased() },
                ])
            }
            return []
        }
        showHighlight()
        // impl: LIST-001 rule 4 — the badge tracks ⌥ for as long as the drag
        // lasts, because the user can press or release it mid-drag and the
        // highlight is the only thing that tells them which one they will get.
        highlight?.setAppendBadgeVisible(Self.isAppendDrag)
        log(.mediaDragEntered, .info, ["count": urls.count])
        return .copy
    }

    func draggingExited(_ sender: NSDraggingInfo?) {
        guard highlight != nil || rejectionLogged else { return }
        clearHighlight()
        log(.mediaDragExited, .info, [:])
    }

    /// impl: MEDIA-001 rule 6 — the drop route does not open anything itself;
    /// it hands URLs to the one funnel.
    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = Self.fileURLs(on: sender.draggingPasteboard).filter(Self.isAcceptable)
        // impl: LIST-001 rule 4 — read before the highlight goes, so the badge
        // the user saw and the behaviour they get are decided by one value.
        let append = Self.isAppendDrag
        clearHighlight()
        guard !urls.isEmpty else { return false }
        opener.open(urls: urls, reason: .drop, append: append)
        return true
    }

    /// impl: LIST-001 rule 4 — `NSDraggingInfo` carries no modifier state, so
    /// the live keyboard flags are the only source for this.
    private static var isAppendDrag: Bool {
        NSEvent.modifierFlags.contains(.option)
    }

    // MARK: - Highlight

    /// impl: MEDIA-001 rule 9 — 2 pt inset accent border, and the hint changes
    /// to "Release to play" while a valid drag is over the window.
    private func showHighlight() {
        guard highlight == nil else { return }
        let view = DropHighlightView(frame: host.bounds)
        view.autoresizingMask = [.width, .height]
        host.addSubview(view)
        highlight = view
        host.setHintText(.releaseToPlay)
    }

    private func clearHighlight() {
        highlight?.removeFromSuperview()
        highlight = nil
        rejectionLogged = false
        host.setHintText(.dropAVideo)
    }

    // MARK: - Pasteboard

    private static func fileURLs(on pasteboard: NSPasteboard) -> [URL] {
        pasteboard.readObjects(forClasses: [NSURL.self],
                               options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    /// impl: MEDIA-001 rules 2, 10 — video, subtitle sidecar, or a directory
    /// (which rule 2 expands one level deep).
    static func isAcceptable(_ url: URL) -> Bool {
        if FormatCatalog.isVideo(url) || FormatCatalog.isSubtitle(url) { return true }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            && isDir.boolValue
    }
}

/// impl: MEDIA-001 rule 9 — the highlight itself. It traces WIN-001's 10 pt
/// corner radius so the border follows the window's actual shape rather than a
/// square that visibly overshoots the corners.
final class DropHighlightView: NSView {
    /// impl: LIST-001 rule 4 — "this will be added, not replace what is playing".
    private let appendBadge = NSTextField(labelWithString: "+")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        guard let layer else { return }
        layer.borderWidth = 2
        layer.borderColor = NSColor.controlAccentColor.cgColor
        layer.cornerRadius = WindowShapeController.cornerRadius
        layer.cornerCurve = .continuous
        setAccessibilityIdentifier(A11yID.windowDropHighlight.rawValue)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)

        appendBadge.translatesAutoresizingMaskIntoConstraints = false
        appendBadge.font = .systemFont(ofSize: 28, weight: .bold)
        appendBadge.textColor = .controlAccentColor
        appendBadge.isHidden = true
        addSubview(appendBadge)
        NSLayoutConstraint.activate([
            appendBadge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            appendBadge.topAnchor.constraint(equalTo: topAnchor, constant: 12),
        ])
    }

    /// Called by DropTarget on every `draggingUpdated`.
    func setAppendBadgeVisible(_ visible: Bool) {
        guard appendBadge.isHidden == visible else { return }
        appendBadge.isHidden = !visible
        setAccessibilityValue(visible ? "append" : "replace")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Play builds no nibs") }

    /// The highlight is decoration: it must never swallow the drop it decorates.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
