// impl: MEDIA-002 rule 6 — the failure taxonomy.
//
// Every failure resolves to exactly one case with one user-facing sentence and
// one log reason, so no two causes can present as the same generic error.

import Foundation

enum MediaFailure: String, Error, Equatable, Sendable {
    case fileMissing, notReadable, emptyFile, unsupportedExtension
    case noPlayableTrack, decodeFailed, drmProtected

    /// impl: MEDIA-002 rule 6 — the message column of the table, verbatim.
    var message: String {
        switch self {
        case .fileMissing:          "That file isn't there any more."
        case .notReadable:          "Play doesn't have permission to read that file."
        case .emptyFile:            "That file is empty."
        case .unsupportedExtension: "Play doesn't open that kind of file."
        case .noPlayableTrack:      "There's no video or audio in that file."
        case .decodeFailed:         "Play couldn't decode that file."
        case .drmProtected:         "That file is copy-protected."
        }
    }

    /// impl: MEDIA-002 rule 6 — `unsupportedExtension` is the one case whose
    /// message names the extension, so it is built rather than constant.
    func message(forExtension ext: String) -> String {
        self == .unsupportedExtension ? "Play doesn't open .\(ext) files." : message
    }

    var reason: String { rawValue }
}
