// impl: LOG-001 rules 7-8 — media paths never reach the log in the clear.
//
// Filenames are personal data and full paths leak account names and directory
// structure. Called only by EventLog while encoding a payload, so no caller can
// bypass redaction by logging a raw path.

import CryptoKit
import Foundation

enum PathRedactor {
    /// impl: LOG-001 rule 7 — home-relative shortening, opaque hash outside home.
    static func redact(_ url: URL) -> String { redact(url.path) }

    static func redact(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~/…/" + (path as NSString).lastPathComponent
        }
        let ext = (path as NSString).pathExtension
        let h = mrlHash(path)
        return ext.isEmpty ? h : "\(h).\(ext)"
    }

    /// impl: LOG-001 rule 8 — sha256 of the absolute path, 16 hex chars.
    /// Stable within and across sessions so PLAY-004 can key on it, not reversible.
    static func mrlHash(_ path: String) -> String {
        let digest = SHA256.hash(data: Data(path.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    static func mrlHash(_ url: URL) -> String { mrlHash(url.path) }
}
