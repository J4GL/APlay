// impl: WIN-003 rules 8-11 — window frame persistence.
//
// Mirrors TrackPreferencesStore's shape (test-injectable UserDefaults, one
// small class owning one key) rather than inventing a new persistence idiom.

import AppKit

@MainActor
final class WindowGeometryStore {
    private static let key = "window.frame"
    /// impl: WIN-003 rule 9 — "at least 50 % on-screen against the current
    /// display arrangement".
    private static let minOnScreenFraction: CGFloat = 0.5

    /// impl: WIN-003 rule 8 — 500 ms, independent of `WindowGeometryLog`'s own
    /// 200 ms *log*-coalesce (a different concern, already built for WIN-001
    /// rule 14) — kept here so the debounce is part of the store's own,
    /// independently testable contract.
    private static let saveDebounce: TimeInterval = 0.5

    private let defaults: UserDefaults
    private var pendingSave: DispatchWorkItem?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// impl: WIN-003 rule 8 — called on every settled move/resize, via
    /// `WindowGeometryLog`.
    func scheduleSave(_ frame: NSRect) {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save(frame) }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.saveDebounce, execute: work)
    }

    /// impl: WIN-003 rule 8 — called by `scheduleSave`'s debounce and
    /// directly by `AppDelegate.applicationWillTerminate`.
    func save(_ frame: NSRect) {
        pendingSave?.cancel()
        pendingSave = nil
        defaults.set([Double(frame.origin.x), Double(frame.origin.y),
                      Double(frame.size.width), Double(frame.size.height)],
                     forKey: Self.key)
        log(.windowGeometrySaved, .info, [
            "x": Int(frame.origin.x), "y": Int(frame.origin.y),
            "w": Int(frame.size.width), "h": Int(frame.size.height),
        ])
    }

    /// impl: WIN-003 rules 9, 11 — `nil` for "nothing saved" (first launch, or
    /// `defaults delete`, silently — rule 11) and for a saved frame that fails
    /// the on-screen test (logged as discarded).
    func restore() -> NSRect? {
        guard let raw = defaults.array(forKey: Self.key) as? [Double], raw.count == 4 else {
            return nil
        }
        let frame = NSRect(x: raw[0], y: raw[1], width: raw[2], height: raw[3])
        guard frame.width > 0, frame.height > 0 else { return nil }

        guard isSufficientlyOnScreen(frame) else {
            log(.windowGeometryDiscarded, .warn, [
                "reason": "offscreen", "x": Int(frame.origin.x), "y": Int(frame.origin.y),
                "w": Int(frame.size.width), "h": Int(frame.size.height),
            ])
            return nil
        }
        log(.windowGeometryRestored, .info, [
            "x": Int(frame.origin.x), "y": Int(frame.origin.y),
            "w": Int(frame.size.width), "h": Int(frame.size.height),
        ])
        return frame
    }

    /// impl: WIN-003 rule 9 — screens never overlap in AppKit's global
    /// coordinate space, so summing each screen's intersection area equals a
    /// true union-intersection without needing an actual union operation.
    private func isSufficientlyOnScreen(_ frame: NSRect) -> Bool {
        let frameArea = frame.width * frame.height
        guard frameArea > 0 else { return false }
        let intersected = NSScreen.screens.reduce(CGFloat(0)) { total, screen in
            let overlap = screen.frame.intersection(frame)
            return total + overlap.width * overlap.height
        }
        return intersected >= frameArea * Self.minOnScreenFraction
    }
}
