// impl: VLC-002 rules 4-7 — libvlc's C callbacks turned into ordered,
// main-actor state changes.
//
// THE RULE THAT MATTERS (VLC-002 rule 6): libvlc holds an internal lock while
// dispatching events. Calling back into libvlc from inside a callback re-enters
// that lock and hangs the app permanently. Every callback body does exactly one
// thing: extract scalars, then hop to main.

import Foundation

/// impl: VLC-002 rule 10 — the only thing that crosses the thread boundary:
/// a plain value type of scalars.
struct VLCEvent: Sendable {
    enum Kind: Sendable {
        case opening, playing, paused, stopped, endReached, encounteredError
        case timeChanged(ms: Int)
        case lengthChanged(ms: Int)
        case seekableChanged(Bool)
        case vout(count: Int)
        case esAdded, esDeleted
    }
    let kind: Kind
}

@MainActor
final class VLCEventBridge {
    /// impl: VLC-002 rule 4 — the attached set.
    static let attachedEvents: [libvlc_event_e] = [
        libvlc_MediaPlayerOpening, libvlc_MediaPlayerPlaying, libvlc_MediaPlayerPaused,
        libvlc_MediaPlayerStopped, libvlc_MediaPlayerEndReached,
        libvlc_MediaPlayerEncounteredError, libvlc_MediaPlayerTimeChanged,
        libvlc_MediaPlayerLengthChanged, libvlc_MediaPlayerSeekableChanged,
        libvlc_MediaPlayerVout, libvlc_MediaPlayerESAdded, libvlc_MediaPlayerESDeleted,
    ]

    /// The single consumer. Set by MediaPlayer at construction.
    var onEvent: ((VLCEvent) -> Void)?

    // impl: VLC-002 rule 7 — coalesce time updates to at most one per 100 ms,
    // always the newest. Other event types are never coalesced or dropped.
    private var lastTimeDelivery: DispatchTime = .now()
    private static let timeCoalesceNs: UInt64 = 100_000_000

    nonisolated init() {}

    func deliver(_ event: VLCEvent) {
        if case .timeChanged = event.kind {
            let now = DispatchTime.now()
            guard now.uptimeNanoseconds - lastTimeDelivery.uptimeNanoseconds
                    >= Self.timeCoalesceNs else { return }
            lastTimeDelivery = now
        }
        onEvent?(event)
    }
}

/// impl: VLC-002 rule 6 — the whole callback body. No libvlc calls. No locks.
/// No allocation beyond the value type. Just extract and hop.
func vlcEventTrampoline(_ rawEvent: UnsafePointer<libvlc_event_t>?,
                        _ ctx: UnsafeMutableRawPointer?) {
    guard let rawEvent, let ctx else { return }
    let e = rawEvent.pointee

    let kind: VLCEvent.Kind? = switch libvlc_event_e(UInt32(e.type)) {
    case libvlc_MediaPlayerOpening:          .opening
    case libvlc_MediaPlayerPlaying:          .playing
    case libvlc_MediaPlayerPaused:           .paused
    case libvlc_MediaPlayerStopped:          .stopped
    case libvlc_MediaPlayerEndReached:       .endReached
    case libvlc_MediaPlayerEncounteredError: .encounteredError
    case libvlc_MediaPlayerTimeChanged:      .timeChanged(ms: Int(e.u.media_player_time_changed.new_time))
    case libvlc_MediaPlayerLengthChanged:    .lengthChanged(ms: Int(e.u.media_player_length_changed.new_length))
    case libvlc_MediaPlayerSeekableChanged:  .seekableChanged(e.u.media_player_seekable_changed.new_seekable != 0)
    case libvlc_MediaPlayerVout:             .vout(count: Int(e.u.media_player_vout.new_count))
    case libvlc_MediaPlayerESAdded:          .esAdded
    case libvlc_MediaPlayerESDeleted:        .esDeleted
    default:                                 nil
    }
    guard let kind else { return }

    let bridge = Unmanaged<VLCEventBridge>.fromOpaque(ctx)
    let event = VLCEvent(kind: kind)
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            bridge.takeUnretainedValue().deliver(event)
        }
    }
}
