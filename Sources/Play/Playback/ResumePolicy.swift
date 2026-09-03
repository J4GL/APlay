// impl: PLAY-004 rule 6 — the save/skip decision, isolated so it is testable
// without a store or a player.

import Foundation

enum ResumeSkipReason: String {
    case tooEarly, tooLate, tooShort
}

enum ResumePolicy {
    /// impl: PLAY-004 rule 6 — deliberately blunt and not configurable; there
    /// is no settings UI in this player.
    static let earlyThresholdMs = 30_000
    static let lateThresholdMs = 60_000
    static let minimumLengthMs = 120_000

    static func skipReason(positionMs: Int, lengthMs: Int) -> ResumeSkipReason? {
        guard lengthMs >= minimumLengthMs else { return .tooShort }
        guard positionMs >= earlyThresholdMs else { return .tooEarly }
        guard positionMs <= lengthMs - lateThresholdMs else { return .tooLate }
        return nil
    }
}
