// impl: WIN-003 rules 2, 6, 13 — every ratio decision, as pure arithmetic.
//
// Nothing here touches a window, a screen or libvlc: the values come in as
// numbers and leave as numbers, so the shape the window takes is unit-testable
// without a running app. `AspectRatioLock` is the only caller.

import AppKit

struct VideoGeometry: Equatable {
    /// What `libvlc_video_get_size` reported — storage pixels, not display size.
    let pixelSize: NSSize
    /// impl: WIN-003 rule 2 — 1 when the container declares no SAR, which is
    /// the overwhelmingly common case and must not be read as "unknown ratio".
    let sampleAspectRatio: CGFloat

    /// impl: WIN-001-S2 — the floor that applies with no video loaded, and the
    /// one restored whenever the lock is released (WIN-003 rules 13, 14).
    static let unlockedMinimum = NSSize(width: 320, height: 180)

    init?(pixelSize: NSSize, sarNum: Int, sarDen: Int) {
        guard pixelSize.width > 0, pixelSize.height > 0 else { return nil }
        self.pixelSize = pixelSize
        self.sampleAspectRatio = sarNum > 0 && sarDen > 0
            ? CGFloat(sarNum) / CGFloat(sarDen)
            : 1
    }

    /// impl: WIN-003 rule 2 — anamorphic 720 x 576 with SAR 64:45 is 16:9, not
    /// 5:4. The storage ratio alone is the wrong answer on every DVD-era file.
    var displayAspectRatio: CGFloat {
        (pixelSize.width * sampleAspectRatio) / pixelSize.height
    }

    /// impl: WIN-003 rule 13 — the smallest size that keeps `ratio` and is still
    /// at least 320 x 180. Widescreen is bounded by the height, 4:3 and taller by
    /// the width.
    static func minimumContentSize(ratio: CGFloat) -> NSSize {
        guard ratio > 0 else { return unlockedMinimum }
        let fromWidth = NSSize(width: unlockedMinimum.width,
                               height: (unlockedMinimum.width / ratio).rounded(.up))
        guard fromWidth.height < unlockedMinimum.height else { return fromWidth }
        return NSSize(width: (unlockedMinimum.height * ratio).rounded(.up),
                      height: unlockedMinimum.height)
    }

    /// impl: WIN-003 rule 6 — keep the width the user already chose and derive
    /// the height; scale both down when that height does not fit, and never go
    /// below rule 13's minimum.
    static func contentSize(ratio: CGFloat,
                            keepingWidthOf current: NSSize,
                            within limit: NSSize?) -> NSSize {
        guard ratio > 0, current.width > 0, current.height > 0 else { return current }
        var size = NSSize(width: current.width.rounded(),
                          height: (current.width / ratio).rounded())

        if let limit, limit.width > 0, limit.height > 0 {
            let scale = min(limit.width / size.width, limit.height / size.height)
            if scale < 1 {
                size = NSSize(width: (size.width * scale).rounded(.down),
                              height: (size.height * scale).rounded(.down))
            }
        }

        let minimum = minimumContentSize(ratio: ratio)
        // Both axes are compared, because the scale-down above can undershoot on
        // either one depending on which limit bit first.
        if size.width < minimum.width || size.height < minimum.height { return minimum }
        return size
    }

    /// impl: WIN-003 rule 6 — the resize happens around the window's centre, so
    /// a reshaped window stays where the user put it instead of growing from its
    /// bottom-left corner.
    static func recentred(_ frame: NSRect, toFrameSize size: NSSize) -> NSRect {
        NSRect(x: (frame.midX - size.width / 2).rounded(),
               y: (frame.midY - size.height / 2).rounded(),
               width: size.width, height: size.height)
    }

    /// impl: WIN-003 rule 6 — growing around the centre can push the frame under
    /// the menu bar or off the bottom of the screen; it is nudged back rather
    /// than shrunk, so the ratio survives the correction.
    static func nudgedInside(_ frame: NSRect, visibleFrame: NSRect) -> NSRect {
        guard visibleFrame.width > 0, visibleFrame.height > 0 else { return frame }
        var moved = frame
        if moved.maxX > visibleFrame.maxX { moved.origin.x = visibleFrame.maxX - moved.width }
        if moved.minX < visibleFrame.minX { moved.origin.x = visibleFrame.minX }
        if moved.maxY > visibleFrame.maxY { moved.origin.y = visibleFrame.maxY - moved.height }
        if moved.minY < visibleFrame.minY { moved.origin.y = visibleFrame.minY }
        return moved
    }
}
