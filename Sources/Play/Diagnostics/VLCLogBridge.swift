// impl: LOG-001 rule 6 — libvlc's own log, re-emitted under subsystem "vlc".
//
// The callback obeys the VLC-002 rule 6 deadlock rule: it formats and hands off,
// and calls no libvlc function.

import Foundation

final class VLCLogBridge: @unchecked Sendable {
    private let instance: OpaquePointer
    private var attached = false

    init(instance: OpaquePointer) {
        self.instance = instance
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        libvlc_log_set(instance, vlcLogTrampoline, ctx)
        attached = true
    }

    func detach() {
        guard attached else { return }
        libvlc_log_unset(instance)
        attached = false
    }

    /// impl: VLC-001 rule 19 — the option prefixes whose absence is a designed
    /// consequence of the plugin allowlist, not a defect. Nothing else is demoted.
    static let expectedMissingOptions = [
        "vmem-", "amem-", "marq-", "logo-", "equalizer-",
        "contrast", "brightness", "hue", "saturation", "gamma",
    ]

    /// impl: VLC-001 rule 19 / VLC-001-S4 — true only for
    /// `option <name> does not exist` where `<name>` is in the allowlist above.
    /// Exposed so VLC-001-S4 can prove it is an allowlist, not a catch-all.
    static func demote(_ message: String) -> Bool {
        guard message.hasPrefix("option "), message.hasSuffix(" does not exist") else { return false }
        let name = message.dropFirst("option ".count).dropLast(" does not exist".count)
        return expectedMissingOptions.contains { name.hasPrefix($0) }
    }

    /// Called from the trampoline, already off libvlc's stack in the sense that
    /// it performs no libvlc calls.
    fileprivate func emit(level: Int32, message: String) {
        // libvlc's levels are NOT contiguous — vlc/libvlc.h declares
        // LIBVLC_DEBUG=0, LIBVLC_NOTICE=2, LIBVLC_WARNING=3, LIBVLC_ERROR=4.
        // Treating them as 0..3 promoted every warning to an error.
        var mapped: LogLevel = switch level {
        case Int32(LIBVLC_DEBUG.rawValue):   .debug
        case Int32(LIBVLC_NOTICE.rawValue):  .info
        case Int32(LIBVLC_WARNING.rawValue): .warn
        default:                             .error
        }
        // impl: VLC-001 rule 19
        if mapped == .error, Self.demote(message) { mapped = .debug }
        log(.vlcLog, mapped, ["message": message])
    }
}

// impl: VLC-002 rule 6 — value extraction only; no libvlc calls, no locks.
private func vlcLogTrampoline(
    _ data: UnsafeMutableRawPointer?,
    _ level: Int32,
    _ ctx: OpaquePointer?,
    _ fmt: UnsafePointer<CChar>?,
    _ args: CVaListPointer?
) {
    guard let data, let fmt, let args else { return }
    let message = NSString(format: String(cString: fmt), arguments: args) as String
    let bridge = Unmanaged<VLCLogBridge>.fromOpaque(data).takeUnretainedValue()
    bridge.emit(level: level, message: message)
}
