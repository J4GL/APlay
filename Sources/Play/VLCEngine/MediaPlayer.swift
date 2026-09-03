// impl: VLC-002 rules 1-3, 5 — the sole owner of libvlc_media_player_t.
//
// This is the ONLY file that calls libvlc_media_player_* (docs/call-graph.md
// sole-owner table). Everything else goes through TransportController.

import AppKit
import Foundation

@MainActor
final class MediaPlayer {
    private let instance: OpaquePointer
    private let player: OpaquePointer
    private let bridge = VLCEventBridge()
    private var callbacksAttached = false

    /// impl: VLC-002 rule 1 — created once, at first media open, and reused.
    init?(runtime: VLCRuntime, state: PlaybackState) {
        guard let instance = runtime.instance,
              let player = libvlc_media_player_new(instance) else {
            log(.engineError, .error, ["stage": "media_player_new"])
            return nil
        }
        self.instance = instance
        self.player = player

        bridge.onEvent = { [weak state] event in state?.apply(event) }
        attachCallbacks()
        log(.enginePlayerCreated, .info, [:])
    }

    // MARK: - Event wiring

    /// impl: VLC-002 rule 5 — unretained context; the bridge outlives every
    /// attachment because detach happens first in shutdown() (rule 3).
    private func attachCallbacks() {
        guard let manager = libvlc_media_player_event_manager(player) else { return }
        let ctx = Unmanaged.passUnretained(bridge).toOpaque()
        for type in VLCEventBridge.attachedEvents {
            libvlc_event_attach(manager, Int32(type.rawValue), vlcEventTrampoline, ctx)
        }
        callbacksAttached = true
        log(.engineCallbacksAttached, .debug, ["count": VLCEventBridge.attachedEvents.count])
    }

    private func detachCallbacks() {
        guard callbacksAttached, let manager = libvlc_media_player_event_manager(player) else { return }
        let ctx = Unmanaged.passUnretained(bridge).toOpaque()
        for type in VLCEventBridge.attachedEvents {
            libvlc_event_detach(manager, Int32(type.rawValue), vlcEventTrampoline, ctx)
        }
        callbacksAttached = false
        log(.engineCallbacksDetached, .debug, [:])
    }

    // MARK: - Video output

    /// impl: VLC-001 rule 16 / WIN-001 — the video view is handed to libvlc once.
    /// Called only by AppDelegate after the window exists.
    func attachVideoOutput(to view: NSView) {
        libvlc_media_player_set_nsobject(player, Unmanaged.passUnretained(view).toOpaque())
    }

    // MARK: - Media

    /// impl: VLC-002 rules 1-2 — swap the media, release our reference at once;
    /// set_media has already retained it. Called only by FileOpener and Queue.
    func setMedia(url: URL) -> Bool {
        guard let media = url.isFileURL
            ? libvlc_media_new_path(instance, url.path)
            : libvlc_media_new_location(instance, url.absoluteString) else {
            log(.engineError, .error, ["stage": "media_new", "mrlHash": PathRedactor.mrlHash(url)])
            return false
        }
        libvlc_media_player_set_media(player, media)
        libvlc_media_release(media)
        log(.engineMediaSet, .info, ["mrlHash": PathRedactor.mrlHash(url)])
        return true
    }

    /// impl: TRACK-001 rule 9 — external subtitles, added without interrupting
    /// playback. Called only by SubtitleController.addExternal.
    func addSubtitleSlave(url: URL, select: Bool) -> Bool {
        libvlc_media_player_add_slave(
            player, libvlc_media_slave_type_subtitle, url.absoluteString, select) == 0
    }

    // MARK: - Elementary streams (called only by TrackCatalog)

    /// impl: TRACK-001 rule 2 / TRACK-003 rule 2 — one elementary stream as
    /// libvlc reports it, before any naming policy is applied.
    struct RawTrack {
        let id: Int32
        /// The description list's name — the only naming available for external
        /// slaves, which carry no media-level metadata.
        var listName: String = ""
        /// `psz_description`, i.e. the track's own title when the container has one.
        var title: String?
        /// ISO 639 code as libvlc reports it (usually 3-letter, e.g. `eng`).
        var language: String?
        var channels: Int = 0
    }

    /// impl: TRACK-001 rule 1 — the subtitle description list. libvlc's own
    /// "Disable" entry (id −1) is dropped here; TRACK-001 rule 3's Off entry is
    /// ours to model, not libvlc's to supply.
    func subtitleTracks() -> [RawTrack] {
        merge(Self.drain(libvlc_video_get_spu_description(player)),
              with: metadata(ofType: libvlc_track_text))
    }

    /// impl: TRACK-003 rule 1
    func audioTracks() -> [RawTrack] {
        merge(Self.drain(libvlc_audio_get_track_description(player)),
              with: metadata(ofType: libvlc_track_audio))
    }

    private func merge(_ descriptions: [(id: Int32, name: String)],
                       with metadata: [Int32: RawTrack]) -> [RawTrack] {
        descriptions.compactMap { entry in
            guard entry.id >= 0 else { return nil }
            var track = metadata[entry.id] ?? RawTrack(id: entry.id)
            track.listName = entry.name
            return track
        }
    }

    private static func drain(
        _ head: UnsafeMutablePointer<libvlc_track_description_t>?
    ) -> [(id: Int32, name: String)] {
        var out: [(id: Int32, name: String)] = []
        var node = head
        while let current = node {
            let name = current.pointee.psz_name.map { String(cString: $0) } ?? ""
            out.append((id: current.pointee.i_id, name: name))
            node = current.pointee.p_next
        }
        if let head { libvlc_track_description_list_release(head) }
        return out
    }

    /// The language, title and channel count the description list does not carry.
    /// `libvlc_media_player_get_media` returns a retained reference, so it is
    /// released here — leaking it would pin every played file's media object.
    private func metadata(ofType wanted: libvlc_track_type_t) -> [Int32: RawTrack] {
        guard let media = libvlc_media_player_get_media(player) else { return [:] }
        defer { libvlc_media_release(media) }

        var list: UnsafeMutablePointer<UnsafeMutablePointer<libvlc_media_track_t>?>?
        let count = libvlc_media_tracks_get(media, &list)
        guard let list, count > 0 else { return [:] }
        defer { libvlc_media_tracks_release(list, count) }

        var out: [Int32: RawTrack] = [:]
        for index in 0..<Int(count) {
            guard let raw = list[index], raw.pointee.i_type == wanted else { continue }
            let track = raw.pointee
            out[track.i_id] = RawTrack(
                id: track.i_id,
                title: track.psz_description.map { String(cString: $0) },
                language: track.psz_language.map { String(cString: $0) },
                channels: wanted == libvlc_track_audio
                    ? Int(track.audio?.pointee.i_channels ?? 0) : 0)
        }
        return out
    }

    // MARK: - Track selection

    /// impl: TRACK-001 rule 5 — the only caller of `libvlc_video_set_spu` is
    /// SubtitleController; this is its one door into libvlc.
    func setSubtitleTrack(id: Int32) -> Bool { libvlc_video_set_spu(player, id) == 0 }
    var subtitleTrackID: Int32 { libvlc_video_get_spu(player) }

    /// impl: TRACK-003 rule 5 — likewise for AudioTrackController.
    func setAudioTrack(id: Int32) -> Bool { libvlc_audio_set_track(player, id) == 0 }
    var audioTrackID: Int32 { libvlc_audio_get_track(player) }

    /// impl: TRACK-002 rule 3 — libvlc takes **microseconds**. The conversion
    /// itself lives in SubtitleDelayController, which is this method's only
    /// caller; nothing else in the app passes a µs value anywhere.
    func setSubtitleDelay(microseconds: Int64) {
        libvlc_video_set_spu_delay(player, microseconds)
    }
    var subtitleDelayMicroseconds: Int64 { libvlc_video_get_spu_delay(player) }

    // MARK: - Transport (called only by TransportController)

    func play() { libvlc_media_player_play(player) }
    func pause() { libvlc_media_player_set_pause(player, 1) }
    func resume() { libvlc_media_player_set_pause(player, 0) }
    func stop() { libvlc_media_player_stop(player) }

    var isPlaying: Bool { libvlc_media_player_is_playing(player) != 0 }
    var timeMs: Int { Int(libvlc_media_player_get_time(player)) }
    var lengthMs: Int { Int(libvlc_media_player_get_length(player)) }

    /// impl: PLAY-002 rule 10 — seeking is refused, not attempted, on
    /// non-seekable media.
    var isSeekable: Bool { libvlc_media_player_is_seekable(player) != 0 }

    func setTime(ms: Int) { libvlc_media_player_set_time(player, libvlc_time_t(ms)) }

    /// impl: PLAY-003 rule 1 — 0…125 maps straight onto libvlc's own scale.
    /// Called only by VolumeController.
    func setVolume(percent: Int) { libvlc_audio_set_volume(player, Int32(percent)) }
    func setMuted(_ muted: Bool) { libvlc_audio_set_mute(player, muted ? 1 : 0) }

    /// impl: WIN-003 rules 1-2 — the storage pixel size, and the sample aspect
    /// ratio it has to be combined with to get a display ratio. Valid only after
    /// `MediaPlayerVout`: before the vout exists this answers 0 x 0.
    /// Called only by `AspectRatioLock.videoDidAppear`.
    func videoDisplayGeometry() -> (pixelSize: NSSize, sarNum: Int, sarDen: Int)? {
        var w: UInt32 = 0, h: UInt32 = 0
        guard libvlc_video_get_size(player, 0, &w, &h) == 0, w > 0, h > 0 else { return nil }
        let sar = sampleAspectRatio() ?? (num: 1, den: 1)
        return (NSSize(width: Int(w), height: Int(h)), sar.num, sar.den)
    }

    /// impl: WIN-003 rule 2 — `i_sar_num` / `i_sar_den` off the first video ES.
    /// The media reference is retained by `get_media` and released here, as in
    /// `metadata(ofType:)`.
    private func sampleAspectRatio() -> (num: Int, den: Int)? {
        guard let media = libvlc_media_player_get_media(player) else { return nil }
        defer { libvlc_media_release(media) }

        var list: UnsafeMutablePointer<UnsafeMutablePointer<libvlc_media_track_t>?>?
        let count = libvlc_media_tracks_get(media, &list)
        guard let list, count > 0 else { return nil }
        defer { libvlc_media_tracks_release(list, count) }

        for index in 0..<Int(count) {
            guard let raw = list[index], raw.pointee.i_type == libvlc_track_video,
                  let video = raw.pointee.video else { continue }
            return (num: Int(video.pointee.i_sar_num), den: Int(video.pointee.i_sar_den))
        }
        return nil
    }

    /// impl: VLC-002 rule 3 — detach → stop → release, in that order.
    /// Called only by AppDelegate.applicationWillTerminate.
    func shutdown() {
        detachCallbacks()
        libvlc_media_player_stop(player)
        libvlc_media_player_release(player)
        log(.enginePlayerReleased, .info, [:])
    }
}
