// impl: TRACK-001 rules 3, 5, 7 · TRACK-003 rules 4-5, 7 — the track lists as
// a menu.
//
// One view for both subtitle and audio tracks: the rows, the Off entry and the
// check-mark rule are identical, and two copies would drift.

import AppKit
import PlayA11y

@MainActor
enum TrackMenu {
    /// What the menu is listing. Determines the identifier, the Off wording and
    /// the log line, and nothing else.
    enum Kind {
        case subtitles, audio

        var menuIdentifier: A11yID {
            switch self {
            case .subtitles: .menuSubtitleTracks
            case .audio: .menuAudioTracks
            }
        }

        /// impl: TRACK-001 rule 3 / TRACK-003 rule 4 — Off is always present and
        /// always first.
        var offTitle: String { "Off" }
    }

    /// impl: TRACK-001 rule 3 — Off, then the tracks, with the check mark on the
    /// **confirmed** selection. Called by HUDView when a menu button is pressed.
    static func present(kind: Kind,
                        tracks: [MediaTrack],
                        selectedID: Int32?,
                        below button: NSView,
                        onSelect: @escaping (Int32?) -> Void,
                        onOpen: @escaping () -> Void,
                        onClose: @escaping () -> Void) {
        let menu = NSMenu()
        menu.identifier = NSUserInterfaceItemIdentifier(kind.menuIdentifier.rawValue)
        menu.autoenablesItems = false

        let rows: [(title: String, id: Int32?)] =
            [(kind.offTitle, nil)] + tracks.map { ($0.displayName, Optional($0.id)) }

        for (index, row) in rows.enumerated() {
            let item = TrackMenuItem(title: row.title, trackID: row.id, onSelect: onSelect)
            item.state = row.id == selectedID ? .on : .off
            item.setAccessibilityIdentifier(
                "\(kind.menuIdentifier.rawValue).row.\(index)")
            menu.addItem(item)
        }

        // impl: CTRL-001 rule 5 — an open menu suppresses auto-hide; the HUD
        // vanishing under an open list is unusable.
        onOpen()
        let origin = NSPoint(x: 0, y: button.bounds.height + 6)
        menu.popUp(positioning: nil, at: origin, in: button)
        onClose()
    }
}

/// A menu row that carries its track id, so the action needs no index lookup
/// and cannot address the wrong row after a rebuild.
@MainActor
private final class TrackMenuItem: NSMenuItem {
    private let trackID: Int32?
    private let onSelect: (Int32?) -> Void

    init(title: String, trackID: Int32?, onSelect: @escaping (Int32?) -> Void) {
        self.trackID = trackID
        self.onSelect = onSelect
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("Play builds no nibs") }

    /// The selection itself is logged by the controller, with the value libvlc
    /// confirmed — logging the click as well would assert a change that
    /// TRACK-001 rule 5 has not proven yet.
    @objc private func fire() {
        onSelect(trackID)
    }
}
