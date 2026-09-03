// impl: TRACK-002 rule 4 — the centred, self-hiding value readout.
//
// One element that updates in place, not one per key press: a run of `J`
// presses must show a single continuously-updating readout rather than flicker.

import AppKit
import PlayA11y

@MainActor
final class TransientReadout: NSView {
    /// impl: TRACK-002 rule 4 — 1.5 s after the *last* adjustment.
    private static let holdDuration: TimeInterval = 1.5

    private let label = NSTextField(labelWithString: "")
    private var hideWork: DispatchWorkItem?

    /// impl: CTRL-001 rule 5 — the HUD must not hide out from under a readout
    /// the user is reading. Paired suppress/release, set by AppDelegate.
    var onSuppress: ((HUDSuppression) -> Void)?
    var onRelease: ((HUDSuppression) -> Void)?

    init(identifier: A11yID) {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.7).cgColor
        layer?.cornerRadius = 8
        alphaValue = 0
        isHidden = true

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])

        setAccessibilityIdentifier(identifier.rawValue)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Play builds no nibs") }

    /// impl: TRACK-002 rule 4 — called by AppDelegate on every delay change;
    /// the same element is reused, so exactly one exists throughout.
    func show(_ text: String) {
        label.stringValue = text
        setAccessibilityValue(text)
        if isHidden {
            isHidden = false
            onSuppress?(.transientVisible)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                animator().alphaValue = 1
            }
        }
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdDuration, execute: work)
    }

    private func hide() {
        hideWork = nil
        guard !isHidden else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.isHidden = true }
        }
        onRelease?(.transientVisible)
    }

    /// The readout is a label, never a target: clicks must reach the video.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
