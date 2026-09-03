// impl: PLAY-004 rules 7-8 — the resume offer: text, a "Resume" action, a ✕.
//
// Same self-hiding shape as TransientReadout, but interactive — so unlike it,
// this does not override hitTest to swallow clicks.

import AppKit
import PlayA11y

@MainActor
final class ResumeToast: NSView {
    /// impl: PLAY-004 rule 8 — 8 s, same idiom as FailureBanner/TransientReadout.
    private static let autoDismissDelay: TimeInterval = 8.0

    private let label = NSTextField(labelWithString: "")
    private lazy var resumeButton = TextActionButton(
        identifier: .toastResumeAction, title: "Resume"
    ) { [weak self] in self?.resume() }
    private lazy var dismissButton = TextActionButton(
        identifier: .toastResumeDismiss, title: "✕"
    ) { [weak self] in self?.dismiss(reason: "user") }

    private var dismissWork: DispatchWorkItem?
    private var currentRecord: ResumeRecord?

    /// impl: PLAY-004 rule 7 — the accepted record, for the caller to seek to.
    var onResume: ((ResumeRecord) -> Void)?
    /// impl: PLAY-004 rule 8 — one of `user|timeout|seek|mediaChange`.
    var onDismiss: ((String) -> Void)?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.7).cgColor
        layer?.cornerRadius = 8
        alphaValue = 0
        isHidden = true

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white

        let stack = NSStackView(views: [label, resumeButton, dismissButton])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 12
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])

        setAccessibilityIdentifier(A11yID.toastResume.rawValue)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Play builds no nibs") }

    // MARK: - Presentation

    /// impl: PLAY-004 rule 7 — "Resume from H:MM:SS", called at most once per
    /// offer by ResumeCoordinator.
    func show(_ record: ResumeRecord) {
        currentRecord = record
        let text = "Resume from \(Self.formatted(record.positionMs))"
        label.stringValue = text
        setAccessibilityValue(text)
        if isHidden {
            isHidden = false
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                animator().alphaValue = 1
            }
        }
        scheduleAutoDismiss()
    }

    private func scheduleAutoDismiss() {
        dismissWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.dismiss(reason: "timeout") }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.autoDismissDelay, execute: work)
    }

    private func resume() {
        guard let record = currentRecord else { return }
        dismissWork?.cancel()
        dismissWork = nil
        onResume?(record)
    }

    /// impl: PLAY-004 rule 8 — one of `user|timeout|seek|mediaChange`; the
    /// stored record is untouched either way.
    func dismiss(reason: String) {
        guard !isHidden else { return }
        dismissWork?.cancel()
        dismissWork = nil
        hide()
        onDismiss?(reason)
    }

    /// impl: PLAY-004 rule 7 — acceptance hides the toast without logging a
    /// dismissal; called only by ResumeCoordinator after `onResume`.
    func hideForAcceptance() {
        guard !isHidden else { return }
        dismissWork?.cancel()
        dismissWork = nil
        hide()
    }

    private func hide() {
        currentRecord = nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.isHidden = true }
        }
    }

    /// impl: PLAY-004 rule 7 — the spec's own example, "Resume from 2:00", is
    /// the no-hours form; hours appear only when there are any.
    private static func formatted(_ ms: Int) -> String {
        let totalSeconds = max(0, ms) / 1000
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}

/// A small text-labelled control, for actions that read as words ("Resume",
/// "✕") rather than the HUD's symbol-based `HUDButton`.
@MainActor
private final class TextActionButton: NSView {
    private let label = NSTextField(labelWithString: "")
    private let action: () -> Void

    init(identifier: A11yID, title: String, action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        label.translatesAutoresizingMaskIntoConstraints = false
        label.stringValue = title
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .white
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.topAnchor.constraint(equalTo: topAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        setAccessibilityIdentifier(identifier.rawValue)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Play builds no nibs") }

    override func mouseDown(with event: NSEvent) {
        PressFeedback.flash(self)
    }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        action()
    }

    override func accessibilityPerformPress() -> Bool {
        action()
        return true
    }
}
