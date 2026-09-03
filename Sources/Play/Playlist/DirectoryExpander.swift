// impl: LIST-001 rule 3 · MEDIA-001 rule 2 — turning what was dropped into the
// ordered list of files the queue is built from.
//
// Pure and static: it touches the file system but no player state, so both the
// drop route and MediaIntakeDropTests can exercise it without a live libvlc.

import Foundation

enum DirectoryExpander {
    /// impl: MEDIA-001 rule 2 / LIST-001 rule 3 — a dropped directory is
    /// expanded exactly one level deep, filtered by `FormatCatalog`. One level
    /// is deliberate: recursing into a season folder's `Extras/` would queue
    /// things the user did not point at.
    /// Called by FileOpener.open and by MediaIntakeDropTests.
    static func expand(_ urls: [URL]) -> [URL] {
        var out: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
                  isDir.boolValue else {
                out.append(url)
                continue
            }
            let children = (try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])) ?? []
            out.append(contentsOf: children.filter {
                FormatCatalog.isVideo($0) || FormatCatalog.isSubtitle($0)
            })
        }
        return out
    }

    /// impl: MEDIA-001 rule 2 / LIST-001 rule 3 — Finder-style localised name
    /// order, so `Episode 2` precedes `Episode 10`. Called by FileOpener.open.
    static func inNameOrder(_ urls: [URL]) -> [URL] {
        urls.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
    }
}
