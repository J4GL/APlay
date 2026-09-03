// impl: WIN-001 rules 6-8 — the corner radius, and the mitigation ladder for
// clipping a GL-backed video layer.
//
// Rung reached is recorded in WIN-001's Notes only once WIN-001-H2 passes with
// a real screenshot. Until then this file applies rung 1 and nothing is claimed.

import AppKit

@MainActor
enum WindowShapeController {
    /// impl: WIN-001 rule 6
    static let cornerRadius: CGFloat = 10

    /// impl: WIN-001 rule 8 rung 1 — `masksToBounds` on the container view.
    /// Called by AppDelegate at window creation.
    static func applyCornerRadius(_ radius: CGFloat, to view: NSView) {
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        layer.cornerRadius = radius
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
    }

    /// impl: WIN-001 rule 7 — fullscreen animates to 0 and back, because rounded
    /// corners against a fullscreen display read as notches.
    /// Called by FullscreenController (WIN-002) on enter/exit.
    static func setCornerRadius(_ radius: CGFloat, on view: NSView, animated: Bool) {
        guard let layer = view.layer else { return }
        guard animated else {
            layer.cornerRadius = radius
            return
        }
        let animation = CABasicAnimation(keyPath: "cornerRadius")
        animation.fromValue = layer.cornerRadius
        animation.toValue = radius
        animation.duration = 0.2
        layer.add(animation, forKey: "cornerRadius")
        layer.cornerRadius = radius
    }
}
