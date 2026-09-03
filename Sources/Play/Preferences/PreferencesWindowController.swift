// impl: PREF-001 rules 14-19 — the ⌘, window.
//
// Rule 17 is the structural point: this is a *separate* window, so
// `BorderlessWindow.keyDown` is not in its responder chain and the bare-letter
// bindings of CTRL-002 rule 4 cannot fire while the filter field has focus.
// That is why Play can have a text field at all without moving `S`, `A`, `M`,
// `F`, `H` and `J` behind modifiers.

import AppKit
import PlayA11y

@MainActor
final class PreferencesWindowController: NSObject, NSWindowDelegate {
    private let store: TrackPreferencesStore

    private var window: NSWindow?
    private var audioTable: LanguagePriorityTable?
    private var subtitleTable: LanguagePriorityTable?
    private var audioFilter: NSTextField?
    private var subtitleFilter: NSTextField?

    init(store: TrackPreferencesStore) {
        self.store = store
    }

    // MARK: - Presentation

    /// impl: PREF-001 rule 14 — one window, reused. Called only by
    /// `AppCommands.perform(.openSettings)`, which ⌘, and CTRL-004's Settings…
    /// item both reach.
    @discardableResult
    func show(trigger: String) -> Bool {
        let window = window ?? build()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        log(.preferencesWindowOpened, .info, ["trigger": trigger])
        return true
    }

    private func build() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 430),
            // impl: PREF-001 rule 14 — a titled, closable window, deliberately
            // unlike the borderless shell. Settings are chrome, and chrome is
            // what the player window exists to avoid.
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.contentView = buildContent()
        window.setAccessibilityIdentifier(A11yID.preferencesWindow.rawValue)
        return window
    }

    private func buildContent() -> NSView {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 430))
        root.setAccessibilityIdentifier(A11yID.preferencesWindow.rawValue)
        root.setAccessibilityElement(true)
        root.setAccessibilityRole(.group)
        root.setAccessibilityLabel("Settings")

        // impl: PREF-001 rule 15 — two symmetric sections. They are built by the
        // same code path so the two preferences cannot drift apart in behaviour,
        // which is exactly what rule 1 forbids.
        let (audioBox, audioTable, audioFilter) = section(
            title: "Audio", kind: .audio, preference: store.preference(for: .audio))
        let (subtitleBox, subtitleTable, subtitleFilter) = section(
            title: "Subtitles", kind: .subtitle, preference: store.preference(for: .subtitle))

        self.audioTable = audioTable
        self.subtitleTable = subtitleTable
        self.audioFilter = audioFilter
        self.subtitleFilter = subtitleFilter

        let hint = NSTextField(wrappingLabelWithString:
            "Tracks are chosen by language, in the order listed. "
            + "The filter only breaks a tie between tracks of the same language — "
            + "it never causes a language to be skipped.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [audioBox, subtitleBox, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -16),
            audioBox.widthAnchor.constraint(equalTo: stack.widthAnchor),
            subtitleBox.widthAnchor.constraint(equalTo: stack.widthAnchor),
            hint.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        return root
    }

    /// impl: PREF-001 rule 15 — one section: the ordered list, and the filter.
    private func section(title: String,
                         kind: TrackKind,
                         preference: TrackLanguagePreference)
        -> (NSView, LanguagePriorityTable, NSTextField) {
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        heading.translatesAutoresizingMaskIntoConstraints = false

        let table = LanguagePriorityTable(kind: kind, codes: preference.languages)
        table.onChange = { [weak self] codes in
            self?.apply(languages: codes, for: kind)
        }

        let filterLabel = NSTextField(labelWithString: "Prefer tracks whose name contains")
        filterLabel.font = .systemFont(ofSize: 11)
        filterLabel.textColor = .secondaryLabelColor
        filterLabel.translatesAutoresizingMaskIntoConstraints = false

        let filter = NSTextField(string: preference.nameFilter)
        filter.placeholderString = "e.g. forced"
        filter.translatesAutoresizingMaskIntoConstraints = false
        filter.delegate = self
        filter.setAccessibilityIdentifier(
            (kind == .audio ? A11yID.preferencesAudioNameFilter
                            : A11yID.preferencesSubtitleNameFilter).rawValue)
        filter.setAccessibilityLabel("\(title) name filter")

        let box = NSView()
        box.translatesAutoresizingMaskIntoConstraints = false
        for view in [heading, table, filterLabel, filter] { box.addSubview(view) }

        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: box.topAnchor),
            heading.leadingAnchor.constraint(equalTo: box.leadingAnchor),

            table.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 6),
            table.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: box.trailingAnchor),

            filterLabel.topAnchor.constraint(equalTo: table.bottomAnchor, constant: 10),
            filterLabel.leadingAnchor.constraint(equalTo: box.leadingAnchor),

            filter.topAnchor.constraint(equalTo: filterLabel.bottomAnchor, constant: 4),
            filter.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            filter.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            filter.bottomAnchor.constraint(equalTo: box.bottomAnchor),
        ])
        return (box, table, filter)
    }

    // MARK: - Applying

    private func apply(languages: [String], for kind: TrackKind) {
        var preference = store.preference(for: kind)
        preference.languages = languages
        store.update(preference, for: kind)
    }

    private func apply(filter: String, for kind: TrackKind) {
        var preference = store.preference(for: kind)
        let trimmed = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != preference.nameFilter else { return }
        preference.nameFilter = trimmed
        log(.preferencesFilterChanged, .info, ["kind": kind.rawValue, "filter": trimmed])
        store.update(preference, for: kind)
    }

    // MARK: - Window delegate

    /// impl: PREF-001 rule 18 — closing changes nothing further; every edit was
    /// already applied and persisted.
    func windowWillClose(_ notification: Notification) {
        log(.preferencesWindowClosed, .info, [:])
    }
}

// MARK: - Filter fields

extension PreferencesWindowController: NSTextFieldDelegate {
    /// impl: PREF-001 rule 11 — applied as it is typed, not on a Save button.
    /// This is also the observable half of rule 17: PREF-001-S3 types letters
    /// that are player shortcuts and asserts that only this entry appears.
    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if field === audioFilter { apply(filter: field.stringValue, for: .audio) }
        if field === subtitleFilter { apply(filter: field.stringValue, for: .subtitle) }
    }
}
