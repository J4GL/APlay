// impl: TEST-002 / LOG-001 — reading the session log from a UI test.
//
// Play's UI is chromeless and custom-drawn, so half the assertions in the specs
// are "the log contains X". This is the reader that makes them writable.

import Foundation
import XCTest

struct LogEntry {
    let event: String
    let level: String
    let seq: Int
    let payload: [String: Any]
}

final class SessionLog {
    private let url: URL

    /// The **real** home directory. The XCUITest runner is sandboxed — it runs
    /// out of `~/Library/Containers/gl.j4.PlayUITests.xctrunner` — so
    /// `homeDirectoryForCurrentUser` and `NSHomeDirectory()` both point at the
    /// container, while the app under test (not sandboxed) writes its log to the
    /// real `~/Library/Logs/APlay`. Reading the passwd entry is what bridges them.
    static var realHome: URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir))
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// Finds the session file the app under test just created. Called after
    /// `app.launch()`, with the timestamp taken immediately before it.
    static func newest(after launchedAt: Date, timeout: TimeInterval = 15) throws -> SessionLog {
        let directory = realHome.appendingPathComponent("Library/Logs/APlay", isDirectory: true)
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.creationDateKey]
            )) ?? []
            let candidates = files
                .filter { $0.lastPathComponent.hasPrefix("session-") }
                .filter {
                    let created = (try? $0.resourceValues(forKeys: [.creationDateKey]))?.creationDate
                    return (created ?? .distantPast) >= launchedAt.addingTimeInterval(-1)
                }
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
            if let newest = candidates.first { return SessionLog(url: newest) }
            usleep(100_000)
        }
        // Deliberately a failure, not an XCTSkip. A missing log means the app
        // did not start or LOG-001 is broken; skipping would report green for
        // an app that never ran.
        struct MissingSessionLog: Error, CustomStringConvertible {
            let directory: URL, timeout: TimeInterval
            var description: String {
                "no session log appeared in \(directory.path) within \(timeout) s"
            }
        }
        throw MissingSessionLog(directory: directory, timeout: timeout)
    }

    private init(url: URL) { self.url = url }

    var entries: [LogEntry] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let event = object["event"] as? String else { return nil }
            return LogEntry(event: event,
                            level: object["level"] as? String ?? "",
                            seq: object["seq"] as? Int ?? -1,
                            payload: object["payload"] as? [String: Any] ?? [:])
        }
    }

    func entries(named event: String) -> [LogEntry] {
        entries.filter { $0.event == event }
    }

    /// Every wait in this harness is bounded — no unbounded polling.
    @discardableResult
    func waitForEntry(_ event: String,
                      where predicate: @escaping ([String: Any]) -> Bool = { _ in true },
                      timeout: TimeInterval,
                      file: StaticString = #filePath, line: UInt = #line) -> LogEntry? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let hit = entries(named: event).first(where: { predicate($0.payload) }) {
                return hit
            }
            usleep(100_000)
        }
        XCTFail("timed out after \(timeout) s waiting for '\(event)'", file: file, line: line)
        return nil
    }
}
