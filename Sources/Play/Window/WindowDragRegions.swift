// impl: WIN-001 rule 9 — is this point a drag handle?
//
// Rule 9.3 asks for exactly one owner of that question. It used to be answered
// by a `mouseDownCanMoveWindow` override in each of six view files, which is how
// the dead band came to be missing without anyone noticing: there was no single
// place where its absence was visible.
//
// Pure and `nonisolated`, so the geometry is unit-tested without a window.

import AppKit

enum WindowDragRegions {
    /// impl: WIN-001 rule 9.1 — "near a control" means one thing in this
    /// codebase, not two. The value is the margin already used to inflate the
    /// close button's hover region.
    nonisolated static let exclusionMargin: CGFloat = 8

    enum Classification: String, Equatable, Sendable {
        /// On a control: the control takes the press.
        case control
        /// impl: WIN-001 rule 9.2 — within `exclusionMargin` of a control.
        /// Neither drags, nor toggles playback, nor activates the control:
        /// missing a small button by two points must not fling the window
        /// across the desktop.
        case deadBand
        /// Everything else — the picture, the HUD's own backdrop, the empty
        /// state. Dragging moves the window; clicking toggles playback.
        case dragHandle
    }

    /// impl: WIN-001 rule 9 — `controls` are the *tight* frames of the genuinely
    /// interactive views, in the coordinate space `point` is expressed in. They
    /// are deliberately not the HUD's bounds: a bar spanning the window's full
    /// width would otherwise make the whole lower strip undraggable for the sake
    /// of six small buttons.
    nonisolated static func classify(_ point: NSPoint,
                                     controls: [NSRect],
                                     margin: CGFloat = exclusionMargin) -> Classification {
        for rect in controls where rect.contains(point) { return .control }
        for rect in controls where rect.insetBy(dx: -margin, dy: -margin).contains(point) {
            return .deadBand
        }
        return .dragHandle
    }

    /// The control nearest to a point, for WIN-001 rule 16's log entry. A dead
    /// band with no name in the trace is indistinguishable from a press that was
    /// simply dropped — which is the bug it could otherwise hide.
    nonisolated static func nearestControl(to point: NSPoint,
                                           among controls: [(name: String, rect: NSRect)])
        -> String? {
        controls.min {
            squaredDistance(from: point, to: $0.rect) < squaredDistance(from: point, to: $1.rect)
        }?.name
    }

    nonisolated private static func squaredDistance(from point: NSPoint,
                                                    to rect: NSRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return dx * dx + dy * dy
    }
}
