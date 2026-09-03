// impl: MEDIA-002 rules 7, 10, 11 — the in-window failure banner.
//
// A banner, not a modal: it lets the user drop another file immediately.
// Reuses TransientReadout's self-hiding shape but, unlike it, is interactive
// (the ✕ must be clickable), so it does not override hitTest.

import AppKit
import PlayA11y

@MainActor
final class FailureBanner: NSView {
    /// impl: MEDIA-002 rule 7 — 8 s, same idiom as TransientReadout.
    private static let autoDismissDelay: TimeInterval = 8.0

    enum Dismissal: String { case user, timeout, superseded }

    private let messageLabel = NSTextField(labelWithString: "")
    private let filenameLabel = NSTextField(labelWithString: "")
    private lazy var dismissButton = HUDButton(
        identifier: .bannerMediaFailureDismiss, symbol: "xmark",
        accessibilityLabel: "Dismiss", pointSize: 12
    ) { [weak self] in self?.dismiss(.user) }

    private var dismissWork: DispatchWorkItem?
    private var currentReason: String?

    /// impl: CTRL-001 rule 5 — shares the HUD's suppression mechanism with
    /// TransientReadout/ResumeToast (`.transientVisible`).
    var onSuppress: ((HUDSuppression) -> Void)?
    var onRelease: ((HUDSuppression) -> Void)?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.7).cgColor
        layer?.cornerRadius = 8
        alphaValue = 0
        isHidden = true

        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.font = .systemFont(ofSize: 13, weight: .medium)
        messageLabel.textColor = .white
        messageLabel.lineBreakMode = .byTruncatingTail

        filenameLabel.translatesAutoresizingMaskIntoConstraints = false
        filenameLabel.font = .systemFont(ofSize: 11)
        filenameLabel.textColor = NSColor.white.withAlphaComponent(0.7)
        filenameLabel.lineBreakMode = .byTruncatingMiddle

        let textStack = NSStackView(views: [messageLabel, filenameLabel])
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2

        addSubview(textStack)
        addSubview(dismissButton)
        NSLayoutConstraint.activate([
            textStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            textStack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            textStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            textStack.trailingAnchor.constraint(equalTo: dismissButton.leadingAnchor, constant: -8),

            dismissButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            dismissButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        setAccessibilityIdentifier(A11yID.bannerMediaFailure.rawValue)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Play builds no nibs") }

    // MARK: - Presentation

    /// impl: MEDIA-002 rule 7 — one failure, its message and redacted filename.
    func present(_ failure: MediaFailure, for url: URL) {
        supersedeIfShowing()
        messageLabel.stringValue = failure.message
        filenameLabel.stringValue = PathRedactor.redact(url)
        filenameLabel.isHidden = false
        reveal(reason: failure.reason)
    }

    /// impl: MEDIA-002 rule 10 — the whole queue failed; no single file to name.
    func presentSummary(count: Int) {
        supersedeIfShowing()
        messageLabel.stringValue = "None of those \(count) files could be played"
        filenameLabel.stringValue = ""
        filenameLabel.isHidden = true
        reveal(reason: "allItemsFailed")
    }

    private func supersedeIfShowing() {
        guard !isHidden else { return }
        dismissWork?.cancel()
        logDismissed(dismissal: .superseded)
    }

    private func reveal(reason: String) {
        currentReason = reason
        setAccessibilityValue(messageLabel.stringValue)
        log(.mediaBannerShown, .info, ["reason": reason])
        if isHidden {
            isHidden = false
            onSuppress?(.transientVisible)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                animator().alphaValue = 1
            }
        }
        scheduleAutoDismiss()
    }

    private func scheduleAutoDismiss() {
        dismissWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.dismiss(.timeout) }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.autoDismissDelay, execute: work)
    }

    // MARK: - Dismissal

    private func dismiss(_ dismissal: Dismissal) {
        guard !isHidden else { return }
        dismissWork?.cancel()
        dismissWork = nil
        logDismissed(dismissal: dismissal)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.isHidden = true }
        }
        onRelease?(.transientVisible)
    }

    private func logDismissed(dismissal: Dismissal) {
        log(.mediaBannerDismissed, .info, [
            "reason": currentReason ?? "", "dismissal": dismissal.rawValue,
        ])
    }
}
