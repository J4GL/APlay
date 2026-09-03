// impl: PLAY-004 rules 1-4, 9 — resume.json load/save, atomic write,
// retention, staleness.
//
// Keyed by mrlHash (LOG-001 rule 8, the hash of the absolute path), so the
// store never contains a readable path or filename.

import Foundation

struct ResumeRecord: Codable, Equatable {
    let mrlHash: String
    var positionMs: Int
    var lengthMs: Int
    var updatedAt: Date
}

@MainActor
final class ResumeStore {
    /// impl: PLAY-004 rule 4 — retention.
    private static let maxRecords = 200
    private static let maxAge: TimeInterval = 90 * 24 * 60 * 60
    /// impl: PLAY-004 rule 9 — a stale record differs by more than 2 s.
    private static let staleToleranceMs = 2_000

    private let directoryURL: URL
    private var records: [String: ResumeRecord] = [:]

    static func defaultDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Play", isDirectory: true)
    }

    init(directoryURL: URL = ResumeStore.defaultDirectory()) {
        self.directoryURL = directoryURL
        load()
    }

    private var fileURL: URL { directoryURL.appendingPathComponent("resume.json") }

    // MARK: - Public surface

    /// impl: PLAY-004 rule 9 — nil for no record, or a stale one (discarded
    /// without offering).
    func record(for mrlHash: String, currentLengthMs: Int) -> ResumeRecord? {
        guard let record = records[mrlHash] else { return nil }
        guard abs(record.lengthMs - currentLengthMs) <= Self.staleToleranceMs else {
            records.removeValue(forKey: mrlHash)
            persist()
            log(.playbackResumeSkipped, .info, ["reason": "stale", "mrlHash": mrlHash])
            return nil
        }
        return record
    }

    /// impl: PLAY-004 rule 6 — applies the skip decision; upserts otherwise.
    func save(mrlHash: String, positionMs: Int, lengthMs: Int) {
        if let reason = ResumePolicy.skipReason(positionMs: positionMs, lengthMs: lengthMs) {
            log(.playbackResumeSkipped, .info, ["reason": reason.rawValue, "mrlHash": mrlHash])
            return
        }
        records[mrlHash] = ResumeRecord(
            mrlHash: mrlHash, positionMs: positionMs, lengthMs: lengthMs, updatedAt: Date()
        )
        enforceCountCap()
        persist()
        log(.playbackResumeSaved, .info, ["mrlHash": mrlHash, "positionMs": positionMs])
    }

    /// impl: PLAY-004 rule 5 — called only by PlaybackState on `ended`.
    func clear(mrlHash: String) {
        guard records.removeValue(forKey: mrlHash) != nil else { return }
        persist()
        log(.playbackResumeCleared, .info, ["mrlHash": mrlHash])
    }

    // MARK: - Load

    private func load() {
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        guard let data = try? Data(contentsOf: fileURL) else { return }
        guard let decoded = try? JSONDecoder().decode([ResumeRecord].self, from: data) else {
            // impl: PLAY-004 rule 3 — a store that fails to parse is discarded
            // wholesale and rebuilt empty; not worth an error dialog.
            records = [:]
            log(.playbackResumeStoreReset, .warn, [:])
            persist()
            return
        }
        records = Dictionary(uniqueKeysWithValues: decoded.map { ($0.mrlHash, $0) })
        if evictExpiredAndOverCap() { persist() }
    }

    /// impl: PLAY-004 rule 4 — age-eviction runs once, at launch, per the
    /// rule's literal wording; the count cap is re-checked here too so a
    /// store built before this code existed cannot start over the limit.
    @discardableResult
    private func evictExpiredAndOverCap() -> Bool {
        let before = records.count
        let cutoff = Date().addingTimeInterval(-Self.maxAge)
        records = records.filter { $0.value.updatedAt >= cutoff }
        enforceCountCap()
        return records.count != before
    }

    /// impl: PLAY-004 rule 4 — evicts the oldest `updatedAt` first. Runs at
    /// load and after every save, so a single very long session cannot grow
    /// the store past the cap either.
    private func enforceCountCap() {
        guard records.count > Self.maxRecords else { return }
        let sorted = records.values.sorted { $0.updatedAt < $1.updatedAt }
        for record in sorted.prefix(records.count - Self.maxRecords) {
            records.removeValue(forKey: record.mrlHash)
        }
    }

    // MARK: - Save

    /// impl: PLAY-004 rule 3 — temp file + `replaceItemAt`, so a crash
    /// mid-write cannot corrupt the store.
    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(Array(records.values)) else { return }
        let tempURL = directoryURL.appendingPathComponent(".resume-\(UUID().uuidString).tmp")
        do {
            try data.write(to: tempURL)
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tempURL)
        } catch {
            log(.playbackResumeStoreReset, .error, ["reason": "writeFailed"])
            try? FileManager.default.removeItem(at: tempURL)
        }
    }
}
