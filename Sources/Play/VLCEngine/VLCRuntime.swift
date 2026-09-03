// impl: VLC-001 rules 14-18 — the runtime bootstrap.
//
// One libvlc_instance_t per process, created here and nowhere else.

import Foundation

@MainActor
final class VLCRuntime {
    static let shared = VLCRuntime()

    enum BootstrapFailure: String, Error {
        case pluginDirMissing, pluginDirEmpty, libvlcNewReturnedNull, libraryValidationBlocked

        var message: String {
            switch self {
            case .pluginDirMissing:
                "Play's video engine is missing from the app bundle."
            case .pluginDirEmpty:
                "Play's video engine folder is empty."
            case .libvlcNewReturnedNull:
                "Play's video engine failed to start."
            case .libraryValidationBlocked:
                "macOS blocked Play's video engine from loading."
            }
        }
    }

    private(set) var instance: OpaquePointer?
    private(set) var pluginCount = 0
    private var logBridge: VLCLogBridge?

    private init() {}

    /// impl: VLC-001 rule 14 — called only from AppDelegate.applicationWillFinishLaunching.
    func bootstrap() throws {
        let started = DispatchTime.now().uptimeNanoseconds

        // 1-2. resolve and verify the bundled plugin directory
        let pluginURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/PlugIns/vlc", isDirectory: true)

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: pluginURL.path, isDirectory: &isDir),
              isDir.boolValue else {
            try failBootstrap(.pluginDirMissing)
            return
        }
        let dylibs = (try? FileManager.default.contentsOfDirectory(atPath: pluginURL.path))?
            .filter { $0.hasSuffix(".dylib") } ?? []
        guard !dylibs.isEmpty else {
            try failBootstrap(.pluginDirEmpty)
            return
        }
        pluginCount = dylibs.count

        // 3. impl: VLC-001 rule 14.3 — the supported override on macOS. Deriving
        // the directory from the dylib's own location is not reliable once the
        // layout differs from VLC.app's.
        setenv("VLC_PLUGIN_PATH", pluginURL.path, 1)

        // 4. impl: VLC-001 rule 15
        let argv: [String] = [
            "--no-video-title-show", "--no-osd", "--no-snapshot-preview",
            "--no-stats", "--no-lua", "--intf=dummy", "--quiet",
            // Without this, libvlc attaches sidecar subtitles itself *as well as*
            // TRACK-001 rule 10 doing so, and a film beside two `.srt` files ends
            // up with four subtitle tracks, half of them unlabelled duplicates.
            "--no-sub-autodetect-file",
        ]
        // libvlc_new takes `const char *const *`, so the array element type must
        // be UnsafePointer, not the UnsafeMutablePointer strdup hands back.
        var cargs: [UnsafePointer<CChar>?] = argv.map { UnsafePointer(strdup($0)) }
        defer { cargs.forEach { $0.map { free(UnsafeMutablePointer(mutating: $0)) } } }

        let created: OpaquePointer? = cargs.withUnsafeMutableBufferPointer { buf in
            libvlc_new(Int32(buf.count), buf.baseAddress)
        }

        guard let created else {
            try failBootstrap(.libvlcNewReturnedNull)
            return
        }
        instance = created

        // impl: LOG-001 rule 6 — route libvlc's own log through ours.
        logBridge = VLCLogBridge(instance: created)

        let ms = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        let version = String(cString: libvlc_get_version())

        // 5. impl: VLC-001 rule 14.5
        log(.bootstrapOk, .info, [
            "vlcVersion": version,
            "pluginPath": pluginURL.path,
            "pluginCount": pluginCount,
            "durationMs": ms,
        ])
        // impl: VLC-001 rule 18
        if ms > 1000 {
            log(.bootstrapSlow, .warn, ["durationMs": ms, "pluginCount": pluginCount])
        }
    }

    /// impl: VLC-002 rule 3 — released last, after the player.
    func shutdown() {
        logBridge?.detach()
        logBridge = nil
        if let instance {
            libvlc_release(instance)
            self.instance = nil
        }
    }

    private func failBootstrap(_ reason: BootstrapFailure) throws {
        log(.bootstrapFailed, .error, ["reason": reason.rawValue])
        throw reason
    }
}
