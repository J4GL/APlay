// impl: MEDIA-002 rules 1-3, 5 — the single list of accepted extensions.
//
// Three consumers must never disagree: the NSOpenPanel filter, the drop-target
// acceptance test, and CFBundleDocumentTypes. The Info.plist entries in
// project.yml are generated from this list; if you edit one, edit both.

import Foundation
import UniformTypeIdentifiers

enum FormatCatalog {
    /// impl: MEDIA-002 rule 2
    static let videoExtensions: Set<String> = [
        "mp4", "m4v", "mov", "mkv", "avi", "webm", "flv", "wmv", "mpg", "mpeg",
        "m2ts", "mts", "ts", "vob", "ogv", "3gp", "divx", "asf", "rmvb",
    ]

    /// impl: MEDIA-002 rule 3 — droppable, never playable on their own.
    static let subtitleExtensions: Set<String> = ["srt", "ass", "ssa", "vtt", "sub", "idx"]

    static func isVideo(_ url: URL) -> Bool {
        videoExtensions.contains(url.pathExtension.lowercased())
    }

    static func isSubtitle(_ url: URL) -> Bool {
        subtitleExtensions.contains(url.pathExtension.lowercased())
    }

    /// impl: MEDIA-002 rule 1 — the NSOpenPanel filter reads this and nothing else.
    static var openPanelContentTypes: [UTType] {
        videoExtensions.compactMap { UTType(filenameExtension: $0) }
    }
}
