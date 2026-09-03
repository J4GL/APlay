// impl: CTRL-004 — the application menu bar.
//
// This file discharges CTRL-002 rule 6, which specified a menu bar from the
// beginning and was never built. Two rules make it more than boilerplate:
//
//   rule 3 — only ⌘ bindings carry a `keyEquivalent`. A menu item may expose an
//   action whose key is a bare letter, but claiming that letter would intercept
//   it application-wide and break CTRL-002 rules 4 and 9.
//
//   rule 7 — AppKit matches key equivalents *before* `NSWindow.keyDown`, so
//   every ⌘ binding now arrives through `AppCommands.performFromMenu`. That is
//   where CTRL-002 rule 11's `input.key` entry is kept alive.

import AppKit
import PlayA11y

@MainActor
final class MainMenu: NSObject, NSMenuDelegate, NSMenuItemValidation {
    private let commands: AppCommands
    private let subtitles: SubtitleController
    private let audioTracks: AudioTrackController
    private let fullscreen: FullscreenController

    /// impl: CTRL-004 rule 13 — an open menu must not let the HUD fade out from
    /// under it. Set by AppDelegate to the same suppression the HUD's own popups
    /// use (CTRL-001 rule 5).
    var onSuppress: ((HUDSuppression) -> Void)?
    var onRelease: ((HUDSuppression) -> Void)?

    /// impl: CTRL-004 rule 10 — rebuilt in `menuNeedsUpdate`, so they are
    /// correct on open rather than patched on every ES event.
    private var audioTracksMenu: NSMenu?
    private var subtitleTracksMenu: NSMenu?
    /// The dynamic rows currently in each menu, so `menuNeedsUpdate` can replace
    /// exactly them and leave the fixed commands alone.
    private var dynamicRows: [ObjectIdentifier: [NSMenuItem]] = [:]
    /// The fullscreen item, whose title tracks state (rule 5).
    private var fullscreenItem: NSMenuItem?

    init(commands: AppCommands,
         subtitles: SubtitleController,
         audioTracks: AudioTrackController,
         fullscreen: FullscreenController) {
        self.commands = commands
        self.subtitles = subtitles
        self.audioTracks = audioTracks
        self.fullscreen = fullscreen
        super.init()
    }

    // MARK: - Construction

    /// impl: CTRL-004 rule 1 — the complete map. Called once, by AppDelegate.
    func install() {
        let root = NSMenu()
        root.addItem(applicationMenuItem())
        root.addItem(fileMenuItem())
        root.addItem(playbackMenuItem())
        root.addItem(audioMenuItem())
        root.addItem(subtitleMenuItem())
        root.addItem(windowMenuItem())
        NSApp.mainMenu = root
        observeMenuTracking(of: root)
    }

    /// impl: CTRL-004 rule 2 — always first, and always the process name. The
    /// transport menu is therefore called "Playback": two menus reading "Play"
    /// in one bar is a defect, not a naming preference.
    private func applicationMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "Play")
        menu.addItem(withTitle: "About Play",
                     action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                     keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(item(.openSettings, "Settings…", key: ","))
        menu.addItem(.separator())
        menu.addItem(withTitle: "Hide Play",
                     action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = menu.addItem(withTitle: "Hide Others",
                                      action: #selector(NSApplication.hideOtherApplications(_:)),
                                      keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(withTitle: "Show All",
                     action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(item(.quit, "Quit Play", key: "q"))
        return parent(menu)
    }

    private func fileMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "File")
        menu.setAccessibilityIdentifier(A11yID.menuFile.rawValue)
        menu.addItem(item(.openDocument, "Open…", key: "o"))
        menu.addItem(.separator())
        menu.addItem(item(.closeMedia, "Close Media", key: "."))
        menu.addItem(item(.closeWindow, "Close Window", key: "w"))
        return parent(menu)
    }

    private func playbackMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "Playback")
        menu.setAccessibilityIdentifier(A11yID.menuPlayback.rawValue)
        // impl: CTRL-004 rule 3 — no key equivalent: `Space` claimed here would
        // be intercepted application-wide.
        menu.addItem(item(.togglePlayPause, "Play / Pause"))
        menu.addItem(.separator())
        menu.addItem(item(.seekBackward5, "Seek Back 5 Seconds"))
        menu.addItem(item(.seekForward5, "Seek Forward 5 Seconds"))
        menu.addItem(item(.seekBackward60, "Seek Back 60 Seconds"))
        menu.addItem(item(.seekForward60, "Seek Forward 60 Seconds"))
        menu.addItem(.separator())
        menu.addItem(item(.previousItem, "Previous", key: "["))
        menu.addItem(item(.nextItem, "Next", key: "]"))
        menu.addItem(item(.toggleShuffle, "Shuffle Pending"))
        menu.addItem(.separator())
        menu.addItem(item(.toggleQueuePanel, "Show Queue", key: "l"))
        return parent(menu)
    }

    private func audioMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "Audio")
        menu.setAccessibilityIdentifier(A11yID.menuAudio.rawValue)
        menu.delegate = self
        menu.addItem(item(.volumeUp, "Volume Up"))
        menu.addItem(item(.volumeDown, "Volume Down"))
        menu.addItem(item(.toggleMute, "Mute"))
        menu.addItem(.separator())
        // rule 10's rows are inserted here, before this trailing separator.
        menu.addItem(.separator())
        menu.addItem(item(.cycleAudioTrack, "Next Audio Track"))
        audioTracksMenu = menu
        return parent(menu)
    }

    private func subtitleMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "Subtitle")
        menu.setAccessibilityIdentifier(A11yID.menuSubtitle.rawValue)
        menu.delegate = self
        // rule 10's rows are inserted at the top, before this separator.
        menu.addItem(.separator())
        menu.addItem(item(.cycleSubtitleTrack, "Next Subtitle Track"))
        menu.addItem(.separator())
        menu.addItem(item(.subtitleDelayEarlier, "Subtitle Delay Earlier"))
        menu.addItem(item(.subtitleDelayLater, "Subtitle Delay Later"))
        menu.addItem(item(.subtitleDelayReset, "Reset Subtitle Delay"))
        subtitleTracksMenu = menu
        return parent(menu)
    }

    private func windowMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "Window")
        menu.setAccessibilityIdentifier(A11yID.menuWindow.rawValue)
        menu.delegate = self
        menu.addItem(item(.minimise, "Minimise", key: "m"))
        // impl: CTRL-004 rule 5 — the title tracks state, read at validation
        // time rather than kept as a copy that can drift.
        let full = item(.toggleFullscreen, "Enter Full Screen")
        fullscreenItem = full
        menu.addItem(full)
        menu.addItem(.separator())
        menu.addItem(item(.closeWindow, "Close Window", key: "w"))
        return parent(menu)
    }

    /// impl: CTRL-004 rules 13, 15 — **every** menu gets the delegate, not only
    /// the two with dynamic content. Setting it on Audio/Subtitle/Window alone
    /// meant File and Playback logged no `menu.opened` and held no auto-hide
    /// suppression, which rule 15 requires of all of them; CTRL-004-H1 caught it
    /// by timing out on File.
    private func parent(_ menu: NSMenu) -> NSMenuItem {
        menu.delegate = self
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    /// impl: CTRL-004 rules 3, 6 — one item, one `PlayerAction`. `key` is empty
    /// for everything that is not a ⌘ binding; AppKit adds the ⌘ itself.
    private func item(_ action: PlayerAction, _ title: String, key: String = "") -> NSMenuItem {
        let item = ActionMenuItem(action: action, title: title, keyEquivalent: key)
        item.target = self
        item.setAccessibilityIdentifier(A11yID.menuItem(action.rawValue))
        return item
    }

    // MARK: - Firing

    /// impl: CTRL-004 rule 6 — every fixed item lands here, and here funnels
    /// into the single `AppCommands` switch.
    /// `fileprivate` rather than `private`: `ActionMenuItem` below builds the
    /// selector, and it is the only thing outside this type that may.
    @objc fileprivate func fire(_ sender: NSMenuItem) {
        guard let item = sender as? ActionMenuItem else { return }
        commands.performFromMenu(item.playerAction)
    }

    /// impl: CTRL-004 rule 11 — a track row carries its own `Int32?`, never an
    /// index, so it cannot address the wrong track after a catalog rebuild.
    @objc private func selectTrack(_ sender: NSMenuItem) {
        guard let row = sender as? TrackRowMenuItem else { return }
        switch row.kind {
        case .audio: audioTracks.select(row.trackID, source: .user)
        case .subtitles: subtitles.select(row.trackID, source: .user)
        }
    }

    // MARK: - Validation

    /// impl: CTRL-004 rules 5, 8 — preconditions come from `AppCommands`, so the
    /// menu cannot drift from the switch that performs the work.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if let row = menuItem as? TrackRowMenuItem {
            // rule 12 — an Off-only menu is visibly empty rather than absent,
            // but nothing in it is clickable.
            return switch row.kind {
            case .audio: !audioTracks.tracks.isEmpty
            case .subtitles: !subtitles.tracks.isEmpty
            }
        }
        guard let item = menuItem as? ActionMenuItem else { return true }
        if item.playerAction == .toggleFullscreen {
            // rule 5 — read the controller, never a stored copy.
            item.title = fullscreen.isFullscreen ? "Exit Full Screen" : "Enter Full Screen"
        }
        if item.playerAction == .toggleShuffle {
            item.state = (commands.isShuffled?() ?? false) ? .on : .off
        }
        return commands.canPerform(item.playerAction)
    }

    // MARK: - Dynamic track lists

    /// impl: CTRL-004 rules 10, 13, 15 — rebuilt on open, and the HUD held up
    /// for as long as the menu is down.
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === audioTracksMenu {
            rebuildRows(in: menu, kind: .audio, tracks: audioTracks.tracks,
                        selected: audioTracks.selectedID, insertAt: 4)
        }
        if menu === subtitleTracksMenu {
            rebuildRows(in: menu, kind: .subtitles, tracks: subtitles.tracks,
                        selected: subtitles.selectedID, insertAt: 0)
        }
    }

    /// impl: CTRL-004 rules 13, 15 — `menuWillOpen` alone is **not** a signal
    /// that a menu was opened. AppKit sends it to every menu in the bar while
    /// searching for a key equivalent, so one keystroke produced six
    /// open/close pairs: six spurious log entries and six suppress/release
    /// cycles. Tracking is the real signal, and it gates both.
    func menuWillOpen(_ menu: NSMenu) {
        guard isTrackingMenuBar else { return }
        log(.menuOpened, .info, ["menu": menu.title])
    }

    func menuDidClose(_ menu: NSMenu) {
        guard isTrackingMenuBar else { return }
        log(.menuClosed, .info, ["menu": menu.title])
    }

    private var isTrackingMenuBar = false

    /// impl: CTRL-004 rule 13 — the suppression spans the whole interaction with
    /// the bar, not one submenu, so moving between menus does not release it.
    private func observeMenuTracking(of root: NSMenu) {
        let center = NotificationCenter.default
        center.addObserver(forName: NSMenu.didBeginTrackingNotification,
                           object: root, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isTrackingMenuBar = true
                self.onSuppress?(.menuOpen)
            }
        }
        center.addObserver(forName: NSMenu.didEndTrackingNotification,
                           object: root, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isTrackingMenuBar = false
                self.onRelease?(.menuOpen)
            }
        }
    }

    /// impl: CTRL-004 rules 10-12 — Off first, then the catalog's order, with
    /// the check mark on the **confirmed** selection (TRACK-001 rule 5), never
    /// on the requested one.
    private func rebuildRows(in menu: NSMenu,
                             kind: TrackMenu.Kind,
                             tracks: [MediaTrack],
                             selected: Int32?,
                             insertAt index: Int) {
        let key = ObjectIdentifier(menu)
        for stale in dynamicRows[key] ?? [] where menu.items.contains(stale) {
            menu.removeItem(stale)
        }

        let rows: [(title: String, id: Int32?)] =
            [(kind.offTitle, nil)] + tracks.map { ($0.displayName, Optional($0.id)) }
        var inserted: [NSMenuItem] = []
        for (offset, row) in rows.enumerated() {
            let item = TrackRowMenuItem(kind: kind, trackID: row.id, title: row.title)
            item.target = self
            item.action = #selector(selectTrack(_:))
            item.state = row.id == selected ? .on : .off
            menu.insertItem(item, at: index + offset)
            inserted.append(item)
        }
        dynamicRows[key] = inserted
    }
}

// MARK: - Items

/// A menu item that carries its `PlayerAction`, so the action selector needs no
/// lookup table and cannot be wired to the wrong command.
@MainActor
private final class ActionMenuItem: NSMenuItem {
    let playerAction: PlayerAction

    init(action: PlayerAction, title: String, keyEquivalent: String) {
        self.playerAction = action
        super.init(title: title, action: #selector(MainMenu.fire(_:)), keyEquivalent: keyEquivalent)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("Play builds no nibs") }
}

/// impl: CTRL-004 rule 11 — the same pattern `TrackMenu` uses for the HUD popup:
/// the row owns its track id, so a rebuild cannot leave it pointing elsewhere.
@MainActor
private final class TrackRowMenuItem: NSMenuItem {
    let kind: TrackMenu.Kind
    let trackID: Int32?

    init(kind: TrackMenu.Kind, trackID: Int32?, title: String) {
        self.kind = kind
        self.trackID = trackID
        super.init(title: title, action: nil, keyEquivalent: "")
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("Play builds no nibs") }
}
