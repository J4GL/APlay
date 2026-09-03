// impl: LOG-001 — the structured JSONL event log.
//
// This is not a debugging nicety: it is half of the test oracle. Play's UI is
// chromeless and custom-drawn, so many interactions have no standard
// accessibility affordance to assert against. Every scenario that says "the log
// contains X" depends on this file.

import Foundation

public final class EventLog: @unchecked Sendable {
    public static let shared = EventLog()

    private let queue = DispatchQueue(label: "gl.j4.Play.eventlog", qos: .utility)
    private var handle: FileHandle?
    private var seq: Int = 0
    private var minLevel: LogLevel = .info
    private var mirrorToStderr = false
    private var reportedFailure = false
    private(set) public var sessionURL: URL?

    /// `ISO8601DateFormatter` is not `Sendable`; this one is touched only from
    /// `queue`, which is what makes the `@unchecked Sendable` on the class true.
    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    // MARK: - Lifecycle

    /// impl: LOG-001 rule 1 — called from applicationWillFinishLaunching, before
    /// VLCRuntime.bootstrap(), so bootstrap failures are captured.
    public func start() {
        if let raw = ProcessInfo.processInfo.environment["PLAY_LOG_LEVEL"],
           let lvl = LogLevel(rawValue: raw) {
            minLevel = lvl
        }
        #if DEBUG
        mirrorToStderr = true   // impl: LOG-001 rule 13 — never in release
        #endif

        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/APlay", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let stamp = Self.basicStamp(Date())
            let url = dir.appendingPathComponent("session-\(stamp).jsonl")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            handle = try FileHandle(forWritingTo: url)
            sessionURL = url
            prune(in: dir)
        } catch {
            // impl: LOG-001 rule S2 — degrade, do not kill the app, and report once.
            reportFailureOnce(error.localizedDescription)
        }
    }

    /// impl: LOG-001 rule 10 — flush and close on terminate and on signals.
    public func flushAndClose() {
        queue.sync {
            try? handle?.synchronize()
            try? handle?.close()
            handle = nil
        }
    }

    // MARK: - Emitting

    /// impl: LOG-001 rules 3-5 — the one emission point.
    public func log(_ event: LogEvent,
                    _ level: LogLevel = .info,
                    _ payload: [String: Any] = [:]) {
        guard level >= minLevel else { return }
        let now = Date()
        let sanitized = Self.sanitize(payload)

        queue.async { [weak self] in
            guard let self else { return }
            let n = self.seq
            self.seq += 1
            let ts = self.iso.string(from: now)

            var object: [String: Any] = [
                "ts": ts, "level": level.rawValue,
                "subsystem": event.subsystem, "event": event.rawValue,
                "seq": n, "payload": sanitized.mapValues(\.jsonValue),
            ]
            // Keep key order stable for readability; JSONSerialization sorts.
            guard let data = try? JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]
            ) else { return }

            object.removeAll()
            if let h = self.handle {
                h.write(data)
                h.write(Data("\n".utf8))
            }
            if self.mirrorToStderr {
                let line = String(decoding: data, as: UTF8.self)
                FileHandle.standardError.write(Data("[\(level.rawValue)] \(event.rawValue) \(line)\n".utf8))
            }
        }
    }

    /// impl: LOG-001 rule 5 — entry/exit pairs with a duration.
    @discardableResult
    public func traced<T>(_ event: LogEvent, _ body: () throws -> T) rethrows -> T {
        let start = DispatchTime.now().uptimeNanoseconds
        defer {
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            log(event, .trace, ["phase": "exit", "durationMs": ms])
        }
        log(event, .trace, ["phase": "enter"])
        return try body()
    }

    // MARK: - Internals

    /// The sanitized payload crosses onto `queue`, so it must be `Sendable`;
    /// `[String: Any]` is not. Sanitising into this closed set is also what
    /// guarantees LOG-001 rule 7 has seen every value.
    enum LogValue: Sendable {
        case string(String), int(Int), double(Double), bool(Bool)
        case strings([String]), ints([Int])

        var jsonValue: Any {
            switch self {
            case .string(let s):  s
            case .int(let i):     i
            case .double(let d):  d
            case .bool(let b):    b
            case .strings(let a): a
            case .ints(let a):    a
            }
        }
    }

    /// impl: LOG-001 rule 7 — any URL or absolute path in a payload is redacted
    /// here, so no call site can leak one by accident.
    private static func sanitize(_ payload: [String: Any]) -> [String: LogValue] {
        var out: [String: LogValue] = [:]
        for (k, v) in payload {
            switch v {
            case let u as URL:      out[k] = .string(PathRedactor.redact(u))
            case let s as String:   out[k] = .string(s.hasPrefix("/") ? PathRedactor.redact(s) : s)
            case let b as Bool:     out[k] = .bool(b)
            case let i as Int:      out[k] = .int(i)
            case let d as Double:   out[k] = .double(d)
            case let a as [String]: out[k] = .strings(a)
            case let a as [Int]:    out[k] = .ints(a)
            default:                out[k] = .string(String(describing: v))
            }
        }
        return out
    }

    /// impl: LOG-001 rule 11 — keep the newest 20, drop anything over 7 days.
    private func prune(in dir: URL) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]
        ).filter({ $0.lastPathComponent.hasPrefix("session-") }) else { return }

        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        let sorted = files.sorted { $0.lastPathComponent > $1.lastPathComponent }
        var deleted = 0
        for (i, url) in sorted.enumerated() {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? Date()
            if i >= 20 || modified < cutoff {
                if url != sessionURL, (try? fm.removeItem(at: url)) != nil { deleted += 1 }
            }
        }
        if deleted > 0 { log(.appLogPruned, .info, ["deletedCount": deleted]) }
    }

    private func reportFailureOnce(_ reason: String) {
        guard !reportedFailure else { return }
        reportedFailure = true
        FileHandle.standardError.write(Data("logger unavailable: \(reason)\n".utf8))
    }

    private static func basicStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }
}

/// Convenience free function so call sites read as `log(.mediaOpenOk, .info, [...])`.
@inlinable
func log(_ event: LogEvent, _ level: LogLevel = .info, _ payload: [String: Any] = [:]) {
    EventLog.shared.log(event, level, payload)
}
