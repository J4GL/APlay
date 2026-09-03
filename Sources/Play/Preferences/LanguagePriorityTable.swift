// impl: PREF-001 rules 15-16, 19 — one section of the settings window: an
// ordered list of two-letter codes, plus the controls that change it.
//
// Standard AppKit controls on purpose. The player itself is custom-drawn
// because it must be chromeless; a settings window has no such constraint, and
// standard controls come with accessibility, drag reordering and keyboard
// navigation already correct.

import AppKit
import PlayA11y

@MainActor
final class LanguagePriorityTable: NSView {
    /// The pasteboard type used for the reorder drag. Private to this view: the
    /// rows are never dragged anywhere else.
    private static let rowType = NSPasteboard.PasteboardType("gl.j4.Play.languageRow")

    private let kind: TrackKind
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let addField = NSComboBox()
    private let removeButton = NSButton()

    /// impl: PREF-001 rule 2 — the model this view edits: two-letter codes in
    /// the user's order.
    private(set) var codes: [String] = []

    /// impl: PREF-001 rule 11 — every edit is applied immediately; there is no
    /// Save button, because a modal commit would be a second source of truth.
    var onChange: (([String]) -> Void)?

    private let selectable = LanguageCode.selectable()

    init(kind: TrackKind, codes: [String]) {
        self.kind = kind
        self.codes = codes
        super.init(frame: .zero)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Play builds no nibs") }

    // MARK: - Build

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("language"))
        column.title = "Language"
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 22
        tableView.allowsMultipleSelection = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.style = .inset
        // impl: PREF-001 rule 15 — drag to reorder.
        tableView.registerForDraggedTypes([Self.rowType])
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)
        tableView.setAccessibilityIdentifier(languagesID.rawValue)
        tableView.setAccessibilityLabel(
            kind == .audio ? "Audio language priority" : "Subtitle language priority")

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        // impl: PREF-001 rule 16 — one control satisfies both halves of the
        // rule: it lists the languages the system can name, and it accepts a
        // code typed straight in.
        addField.usesDataSource = false
        addField.completes = true
        addField.addItems(withObjectValues: selectable.map { LanguageCode.rowTitle(for: $0) })
        addField.placeholderString = "Add a language (e.g. fr)"
        addField.target = self
        addField.action = #selector(addFromField)
        addField.delegate = self
        addField.translatesAutoresizingMaskIntoConstraints = false
        addField.setAccessibilityIdentifier(addID.rawValue)
        addField.setAccessibilityLabel("Add language")

        removeButton.title = "−"
        removeButton.bezelStyle = .rounded
        removeButton.target = self
        removeButton.action = #selector(removeSelected)
        removeButton.translatesAutoresizingMaskIntoConstraints = false
        removeButton.setAccessibilityIdentifier(removeID.rawValue)
        removeButton.setAccessibilityLabel("Remove language")

        addSubview(scrollView)
        addSubview(addField)
        addSubview(removeButton)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.heightAnchor.constraint(equalToConstant: 110),

            addField.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 8),
            addField.leadingAnchor.constraint(equalTo: leadingAnchor),
            addField.bottomAnchor.constraint(equalTo: bottomAnchor),
            addField.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),

            removeButton.leadingAnchor.constraint(equalTo: addField.trailingAnchor, constant: 8),
            removeButton.centerYAnchor.constraint(equalTo: addField.centerYAnchor),
            removeButton.widthAnchor.constraint(equalToConstant: 32),
            removeButton.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
    }

    private var languagesID: A11yID {
        kind == .audio ? .preferencesAudioLanguages : .preferencesSubtitleLanguages
    }
    private var addID: A11yID {
        kind == .audio ? .preferencesAudioAdd : .preferencesSubtitleAdd
    }
    private var removeID: A11yID {
        kind == .audio ? .preferencesAudioRemove : .preferencesSubtitleRemove
    }

    // MARK: - Mutation

    /// impl: PREF-001 rule 16 — a code that is not two letters is refused at
    /// entry with a reason, never silently coerced into something else.
    @objc private func addFromField() {
        let typed = addField.stringValue
        // The combo box's own rows read "fr — French"; a typed value is bare.
        let candidate = typed.split(separator: "—").first.map(String.init) ?? typed

        guard let code = LanguageCode.normalised(candidate) else {
            log(.preferencesLanguageRejected, .warn, [
                "kind": kind.rawValue, "input": typed, "reason": "notATwoLetterCode",
            ])
            NSSound.beep()
            return
        }
        guard !codes.contains(code) else {
            log(.preferencesLanguageRejected, .warn, [
                "kind": kind.rawValue, "input": typed, "reason": "alreadyPresent",
            ])
            addField.stringValue = ""
            return
        }

        codes.append(code)
        addField.stringValue = ""
        log(.preferencesLanguageAdded, .info, [
            "kind": kind.rawValue, "code": code, "index": codes.count - 1,
        ])
        commit()
    }

    @objc private func removeSelected() {
        let row = tableView.selectedRow
        guard codes.indices.contains(row) else { return }
        let code = codes.remove(at: row)
        log(.preferencesLanguageRemoved, .info, [
            "kind": kind.rawValue, "code": code, "index": row,
        ])
        commit()
    }

    /// impl: PREF-001 rule 11 — reload, then publish. The table is redrawn from
    /// `codes` rather than patched, so a row's identifier can never disagree
    /// with its position (CTRL-003 rule 4).
    private func commit() {
        tableView.reloadData()
        onChange?(codes)
    }
}

// MARK: - Data source (PREF-001 rule 15)

extension LanguagePriorityTable: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int { codes.count }

    /// impl: PREF-001 rule 15 — drag to reorder, and the order *is* the setting.
    func tableView(_ tableView: NSTableView,
                   pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.rowType)
        return item
    }

    func tableView(_ tableView: NSTableView,
                   validateDrop info: NSDraggingInfo,
                   proposedRow row: Int,
                   proposedDropOperation operation: NSTableView.DropOperation)
        -> NSDragOperation {
        operation == .above ? .move : []
    }

    func tableView(_ tableView: NSTableView,
                   acceptDrop info: NSDraggingInfo,
                   row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard let raw = info.draggingPasteboard.pasteboardItems?
            .compactMap({ $0.string(forType: Self.rowType) }).first,
            let from = Int(raw), codes.indices.contains(from) else { return false }

        var to = row
        if from < to { to -= 1 }
        guard from != to, codes.indices.contains(to) else { return false }

        let code = codes.remove(at: from)
        codes.insert(code, at: to)
        log(.preferencesLanguageMoved, .info, [
            "kind": kind.rawValue, "code": code, "from": from, "to": to,
        ])
        commit()
        return true
    }
}

// MARK: - Delegate

extension LanguagePriorityTable: NSTableViewDelegate {
    /// impl: PREF-001 rule 15 — a row reads `fr — French`: the code that is
    /// stored, then the name a person reads, so the stored value is never a
    /// mystery.
    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard codes.indices.contains(row) else { return nil }
        let label = NSTextField(labelWithString: LanguageCode.rowTitle(for: codes[row]))
        label.lineBreakMode = .byTruncatingTail
        // impl: CTRL-003 rule 4 — identified by current position.
        label.setAccessibilityIdentifier(
            A11yID.preferencesLanguageRow(kind.rawValue, row))
        label.setAccessibilityElement(true)
        label.setAccessibilityRole(.staticText)
        label.setAccessibilityLabel(LanguageCode.rowTitle(for: codes[row]))
        return label
    }
}

// MARK: - Combo box

extension LanguagePriorityTable: NSComboBoxDelegate {
    /// Picking from the list is the same act as typing and confirming.
    func comboBoxSelectionDidChange(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let index = self.addField.indexOfSelectedItem as Int?,
                  self.selectable.indices.contains(index) else { return }
            self.addField.stringValue = LanguageCode.rowTitle(for: self.selectable[index])
            self.addFromField()
        }
    }
}
