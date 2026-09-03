// impl: CTRL-001 rule 8 — immediate pressed-state feedback.
//
// PLAY-001 rule 3 makes the state machine non-optimistic: the glyph does not
// change until libvlc says so. This scale animation is what stops that honesty
// from feeling like lag.

import AppKit

@MainActor
enum PressFeedback {
    /// Scale to 0.92 over 60 ms, then back. Applied by every HUD control on
    /// mouse-down, independent of whether the action has taken effect.
    static func flash(_ view: NSView) {
        guard let layer = view.layer else { return }
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.position = CGPoint(x: view.frame.midX, y: view.frame.midY)

        let press = CABasicAnimation(keyPath: "transform.scale")
        press.fromValue = 1.0
        press.toValue = 0.92
        press.duration = 0.06
        press.autoreverses = true
        press.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(press, forKey: "pressFeedback")
    }
}
