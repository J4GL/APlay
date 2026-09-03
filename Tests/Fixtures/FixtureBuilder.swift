// impl: TEST-001 rules 1-4 — deterministic media fixtures, generated never committed.
//
// Every screenshot and seek assertion in every other spec depends on the
// frame-colour guarantee in rule 2: each whole second is one flat colour, and
// second 3 is pure white.

import AVFoundation
import CoreGraphics
import Foundation

/// A monotonic index shared between a pull callback and the caller that
/// scheduled it. `requestMediaDataWhenReady` invokes its block serially on one
/// queue, so a lock is enough to make it Sendable-safe.
private final class Cursor: @unchecked Sendable {
    private var value = 0
    private let lock = NSLock()
    func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        defer { value += 1 }
        return value
    }
}

/// The first error any input queue hit, carried back to the calling thread.
private final class FailureBox: @unchecked Sendable {
    private var stored: Error?
    private let lock = NSLock()
    func record(_ error: Error) {
        lock.lock(); defer { lock.unlock() }
        if stored == nil { stored = error }
    }
    var first: Error? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
}

enum FixtureBuilder {
    /// impl: TEST-001 rule 1 — generated into a gitignored directory, and reused
    /// when the parameters and this version are unchanged.
    static let builderVersion = 1

    enum FixtureError: Error {
        case writerFailed(String)
        case pixelBufferUnavailable
    }

    /// impl: TEST-001 rule 1 — outside the source tree, because the XCUITest
    /// runner is not permitted to write into it.
    ///
    /// Resolved from the passwd entry rather than `homeDirectoryForCurrentUser`
    /// so that all three processes that touch fixtures agree on one path: the
    /// generator script, the **sandboxed** XCUITest runner (whose home is a
    /// container), and Play itself, which is not sandboxed.
    static var generatedDirectory: URL {
        let home: URL
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            home = URL(fileURLWithPath: String(cString: dir))
        } else {
            home = FileManager.default.homeDirectoryForCurrentUser
        }
        return home.appendingPathComponent("Library/Caches/gl.j4.Play/Fixtures", isDirectory: true)
    }

    /// impl: TEST-001 rule 2 — the workhorse: 640 x 360, 30 fps, 10 s, H.264,
    /// one flat colour per second, second 3 pure white.
    /// Palette index 3 is white; the rest are distinguishable at a glance.
    static let palette: [CGColor] = [
        CGColor(red: 0.80, green: 0.10, blue: 0.10, alpha: 1),  // 0 red
        CGColor(red: 0.10, green: 0.60, blue: 0.20, alpha: 1),  // 1 green
        CGColor(red: 0.10, green: 0.25, blue: 0.85, alpha: 1),  // 2 blue
        CGColor(red: 1.00, green: 1.00, blue: 1.00, alpha: 1),  // 3 WHITE (rule 2)
        CGColor(red: 0.95, green: 0.75, blue: 0.05, alpha: 1),  // 4 amber
        CGColor(red: 0.60, green: 0.15, blue: 0.75, alpha: 1),  // 5 violet
        CGColor(red: 0.05, green: 0.70, blue: 0.75, alpha: 1),  // 6 cyan
        CGColor(red: 0.95, green: 0.45, blue: 0.10, alpha: 1),  // 7 orange
        CGColor(red: 0.35, green: 0.35, blue: 0.35, alpha: 1),  // 8 grey
        CGColor(red: 0.02, green: 0.02, blue: 0.02, alpha: 1),  // 9 near-black
    ]

    /// impl: TEST-001 rule 3 — a 4 px border in a distinct colour on all edges.
    static let borderColor = CGColor(red: 1, green: 0, blue: 1, alpha: 1)  // magenta
    static let borderWidth: CGFloat = 4

    /// Returns the colour-bars fixture, generating it only if absent.
    /// Called by every UI test's `setUp` and by MediaFixtureTests.
    static func colorBars10s() throws -> URL {
        let url = generatedDirectory
            .appendingPathComponent("colorbars-10s-v\(builderVersion).mp4")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        try FileManager.default.createDirectory(
            at: generatedDirectory, withIntermediateDirectories: true)
        try write(to: url, width: 640, height: 360, fps: 30, seconds: 10)
        return url
    }

    /// impl: TEST-001 rule 5 — 720 x 576 storage carrying a 16:9 display aspect,
    /// written as a `pasp` atom (PAR 64:45). Its whole purpose is that the
    /// storage ratio (1.25) and the display ratio (1.778) disagree, so WIN-003-S1
    /// can tell a player that reads the SAR from one that does not.
    /// Called by AspectRatioSizingTests.
    static func anamorphic576p() throws -> URL {
        let url = generatedDirectory
            .appendingPathComponent("anamorphic-576p-v\(builderVersion).mp4")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        try FileManager.default.createDirectory(
            at: generatedDirectory, withIntermediateDirectories: true)
        try write(to: url, width: 720, height: 576, fps: 25, seconds: 10,
                  pixelAspect: (horizontal: 64, vertical: 45))
        return url
    }

    /// impl: TEST-001 rule 9 — two audio tracks tagged `eng` and `fra` carrying
    /// different pure tones, so "which track is playing" is a measurement rather
    /// than a matter of trusting the track id.
    static func dualAudio10s() throws -> URL {
        let url = generatedDirectory
            .appendingPathComponent("dual-audio-10s-v\(builderVersion).mp4")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        try FileManager.default.createDirectory(
            at: generatedDirectory, withIntermediateDirectories: true)
        try write(to: url, width: 640, height: 360, fps: 30, seconds: 10,
                  audio: [(language: "eng", hz: 440), (language: "fra", hz: 880)])
        return url
    }

    /// impl: PREF-001-H3 / PREF-001-S1 — two audio tracks **of the same
    /// language**, which is the only situation the name filter exists for.
    ///
    /// Both are tagged `fra`, so the language match cannot separate them and
    /// TRACK-001 rule 4's disambiguation gives them the distinct names "French"
    /// and "French 2" that the filter then has to choose between. Without a
    /// same-language pair the filter is untestable end to end, and its whole
    /// purpose is the tie it breaks.
    static func twoFrenchAudio10s() throws -> URL {
        let url = generatedDirectory
            .appendingPathComponent("two-french-audio-10s-v\(builderVersion).mp4")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        try FileManager.default.createDirectory(
            at: generatedDirectory, withIntermediateDirectories: true)
        try write(to: url, width: 640, height: 360, fps: 30, seconds: 10,
                  audio: [(language: "fra", hz: 440), (language: "fra", hz: 880)])
        return url
    }

    /// impl: TEST-001 rule 8 — a film with sidecar subtitles beside it, in a
    /// directory of its own so the sidecars cannot leak into other fixtures'
    /// TRACK-001 rule-10 scans.
    ///
    /// Returns the film; `fixture.srt` and `fixture.fr.srt` sit next to it.
    static func filmWithSidecars() throws -> URL {
        let directory = generatedDirectory
            .appendingPathComponent("sidecars-v\(builderVersion)", isDirectory: true)
        let film = directory.appendingPathComponent("fixture.mp4")
        if FileManager.default.fileExists(atPath: film.path) { return film }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try write(to: film, width: 640, height: 360, fps: 30, seconds: 10, audio: [])
        try subtitleText(caption: "PLAY SUBTITLE ENGLISH")
            .write(to: directory.appendingPathComponent("fixture.srt"),
                   atomically: true, encoding: .utf8)
        try subtitleText(caption: "PLAY SOUS-TITRE FRANCAIS")
            .write(to: directory.appendingPathComponent("fixture.fr.srt"),
                   atomically: true, encoding: .utf8)
        return film
    }

    /// impl: LIST-001-H1 — three short clips in a directory of their own, named
    /// so localised order is a, b, c. The directory is what the test opens, so
    /// LIST-001 rule 3's one-level expansion is exercised at the same time.
    ///
    /// Returns the directory; `a-first.mp4`, `b-second.mp4`, `c-third.mp4` are
    /// inside it. 5 s each: long enough that LIST-001-H2 can let an item run
    /// past rule 6's 3 s threshold, short enough that a full run is ~15 s.
    static func queueOfThree() throws -> URL {
        let directory = generatedDirectory
            .appendingPathComponent("queue-three-v\(builderVersion)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in ["a-first", "b-second", "c-third"] {
            let url = directory.appendingPathComponent("\(name).mp4")
            guard !FileManager.default.fileExists(atPath: url.path) else { continue }
            try write(to: url, width: 320, height: 180, fps: 30, seconds: 5, audio: [])
        }
        return directory
    }

    /// impl: LIST-001-S1 — a queue whose middle item is a zero-byte `.mp4`, so
    /// the skip-on-failure path can be observed rather than argued about.
    /// Returns the directory holding `a-first.mp4`, `b-broken.mp4`, `c-third.mp4`.
    static func queueWithBrokenMiddleItem() throws -> URL {
        let directory = generatedDirectory
            .appendingPathComponent("queue-broken-v\(builderVersion)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in ["a-first", "c-third"] {
            let url = directory.appendingPathComponent("\(name).mp4")
            guard !FileManager.default.fileExists(atPath: url.path) else { continue }
            try write(to: url, width: 320, height: 180, fps: 30, seconds: 5, audio: [])
        }
        let broken = directory.appendingPathComponent("b-broken.mp4")
        // TEST-001 rule 11 — exactly zero bytes, or MEDIA-002's `emptyFile`
        // branch is not the one being tested.
        if !FileManager.default.fileExists(atPath: broken.path) {
            try Data().write(to: broken)
        }
        return directory
    }

    /// A standalone `.srt` for the drop route (TRACK-001 rule 9), kept out of
    /// any film's directory so it is never picked up as a sidecar.
    static func standaloneSubtitle(named name: String = "dropped") throws -> URL {
        let directory = generatedDirectory
            .appendingPathComponent("subtitles-v\(builderVersion)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(name).srt")
        if !FileManager.default.fileExists(atPath: url.path) {
            try subtitleText(caption: "PLAY DROPPED SUBTITLE")
                .write(to: url, atomically: true, encoding: .utf8)
        }
        return url
    }

    /// impl: TEST-001 rule 2 — one cue per second, so the visible string is a
    /// pure function of the timestamp exactly as the video is.
    private static func subtitleText(caption: String) -> String {
        (0..<10).map { second in
            """
            \(second + 1)
            00:00:0\(second),100 --> 00:00:0\(second),900
            \(caption) \(second)

            """
        }.joined(separator: "\n")
    }

    // MARK: - Writing

    /// Writes to a scratch path and moves the result into place only once the
    /// writer reports success. Without this an interrupted run leaves a partial
    /// file that `fileExists` then happily serves to every later run — which is
    /// exactly how a "damaged media" failure survives the fix that caused it.
    private static func write(to destination: URL, width: Int, height: Int,
                              fps: Int, seconds: Int,
                              audio: [(language: String, hz: Double)] = [],
                              pixelAspect: (horizontal: Int, vertical: Int)? = nil) throws {
        let url = destination.appendingPathExtension("partial")
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: destination)
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        // impl: TEST-001 rule 5 — `AVVideoPixelAspectRatioKey` is what puts a
        // `pasp` atom in the MP4, and `pasp` is where libvlc's `i_sar_num` /
        // `i_sar_den` come from.
        var videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
        if let pixelAspect {
            videoSettings[AVVideoPixelAspectRatioKey] = [
                AVVideoPixelAspectRatioHorizontalSpacingKey: pixelAspect.horizontal,
                AVVideoPixelAspectRatioVerticalSpacingKey: pixelAspect.vertical,
            ]
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        writer.add(input)

        // impl: TEST-001 rule 9 — one writer input per audio track. AVAssetWriter
        // accepts several inputs of the same media type, which is what puts two
        // selectable audio elementary streams in one MP4.
        let audioInputs: [AVAssetWriterInput] = audio.map { track in
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: audioSampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64_000,
            ])
            input.expectsMediaDataInRealTime = false
            // The tag libvlc reports as `psz_language`, and therefore the whole
            // basis of TRACK-001 rule 2's naming and rule 8's default policy.
            input.languageCode = track.language
            writer.add(input)
            return input
        }

        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        // Each input is filled **pull-style**, on its own queue, via
        // `requestMediaDataWhenReady`. Pushing by hand deadlocks as soon as
        // there is more than one input: AVAssetWriter refuses samples from an
        // input that has run ahead of the others, so whichever loop is written
        // first blocks forever waiting for `isReadyForMoreMediaData`. It survived
        // 3 s of audio and hung at 10 s, which made a scheduling bug look like a
        // codec one. This is the API that coordinates the inputs for us.
        let group = DispatchGroup()
        let failures = FailureBox()

        group.enter()
        let videoCursor = Cursor()
        input.requestMediaDataWhenReady(on: DispatchQueue(label: "fixture.video")) {
            while input.isReadyForMoreMediaData {
                let frame = videoCursor.next()
                guard frame < fps * seconds else {
                    input.markAsFinished()
                    group.leave()
                    return
                }
                do {
                    guard let pool = adaptor.pixelBufferPool else {
                        throw FixtureError.pixelBufferUnavailable
                    }
                    var buffer: CVPixelBuffer?
                    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
                    guard let buffer else { throw FixtureError.pixelBufferUnavailable }
                    try draw(second: frame / fps, into: buffer, width: width, height: height,
                             pixelAspect: pixelAspect.map {
                                 CGFloat($0.horizontal) / CGFloat($0.vertical)
                             } ?? 1)
                    guard adaptor.append(buffer, withPresentationTime:
                        CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps))) else {
                        throw FixtureError.writerFailed("video append rejected at frame \(frame)")
                    }
                } catch {
                    failures.record(error)
                    input.markAsFinished()
                    group.leave()
                    return
                }
            }
        }

        for (index, audioInput) in audioInputs.enumerated() {
            group.enter()
            let hz = audio[index].hz
            let cursor = Cursor()
            audioInput.requestMediaDataWhenReady(
                on: DispatchQueue(label: "fixture.audio.\(index)")
            ) {
                while audioInput.isReadyForMoreMediaData {
                    let second = cursor.next()
                    guard second < seconds else {
                        audioInput.markAsFinished()
                        group.leave()
                        return
                    }
                    do {
                        try appendTone(hz: hz, second: second, to: audioInput)
                    } catch {
                        failures.record(error)
                        audioInput.markAsFinished()
                        group.leave()
                        return
                    }
                }
            }
        }

        // impl: TEST-001 rule 1 — bounded; generation must never hang a run.
        guard group.wait(timeout: .now() + 120) == .success else {
            writer.cancelWriting()
            throw FixtureError.writerFailed("inputs did not finish within 120 s")
        }
        if let error = failures.first { throw error }

        // impl: TEST-001 rule 1 — bounded; generation must not hang a test run.
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        guard done.wait(timeout: .now() + 30) == .success else {
            throw FixtureError.writerFailed("finishWriting timed out after 30 s")
        }
        guard writer.status == .completed else {
            throw FixtureError.writerFailed(writer.error?.localizedDescription ?? "unknown")
        }
        try FileManager.default.moveItem(at: url, to: destination)
    }

    // MARK: - Audio

    static let audioSampleRate: Double = 44_100

    private static let toneFormat: AVAudioFormat? = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: audioSampleRate,
        channels: 1, interleaved: true)

    /// impl: TEST-001 rule 9 — one second of a pure tone, appended in step with
    /// the video so the writer's inputs stay on the same timeline.
    private static func appendTone(hz: Double, second: Int,
                                   to input: AVAssetWriterInput) throws {
        guard let format = toneFormat else {
            throw FixtureError.writerFailed("audio format unavailable")
        }
        var description = format.streamDescription.pointee
        var formatDescription: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &description,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &formatDescription) == noErr,
            let formatDescription else {
            throw FixtureError.writerFailed("CMAudioFormatDescriptionCreate failed")
        }

        let framesPerChunk = Int(audioSampleRate)
        var samples = [Int16](repeating: 0, count: framesPerChunk)
        for frame in 0..<framesPerChunk {
            let t = Double(second * framesPerChunk + frame) / audioSampleRate
            samples[frame] = Int16(sin(2 * .pi * hz * t) * 12_000)
        }
        let buffer = try makeSampleBuffer(
            samples: samples, formatDescription: formatDescription,
            presentationTime: CMTime(value: CMTimeValue(second * framesPerChunk),
                                     timescale: CMTimeScale(audioSampleRate)))
        guard input.append(buffer) else {
            throw FixtureError.writerFailed("audio append rejected at second \(second)")
        }
    }

    private static func makeSampleBuffer(
        samples: [Int16], formatDescription: CMAudioFormatDescription,
        presentationTime: CMTime
    ) throws -> CMSampleBuffer {
        let byteCount = samples.count * MemoryLayout<Int16>.size
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: byteCount, flags: 0,
            blockBufferOut: &blockBuffer) == noErr, let blockBuffer else {
            throw FixtureError.writerFailed("CMBlockBufferCreateWithMemoryBlock failed")
        }
        let copied = samples.withUnsafeBytes { raw -> OSStatus in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: blockBuffer,
                                          offsetIntoDestination: 0, dataLength: byteCount)
        }
        guard copied == noErr else {
            throw FixtureError.writerFailed("CMBlockBufferReplaceDataBytes failed")
        }

        var sampleBuffer: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: blockBuffer,
            formatDescription: formatDescription, sampleCount: samples.count,
            presentationTimeStamp: presentationTime, packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer) == noErr, let sampleBuffer else {
            throw FixtureError.writerFailed("CMAudioSampleBufferCreate failed")
        }
        return sampleBuffer
    }

    /// impl: TEST-001 rules 2-5 — flat colour, burned-in numeral, border, circle.
    /// `pixelAspect` is the sample aspect ratio the file declares: the circle is
    /// drawn squashed by it in storage so that it is *round once displayed*,
    /// which is the whole assertion WIN-003-S1 makes.
    private static func draw(second: Int, into buffer: CVPixelBuffer,
                             width: Int, height: Int, pixelAspect: CGFloat = 1) throws {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let ctx = CGContext(
                data: base, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue)
        else { throw FixtureError.pixelBufferUnavailable }

        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        ctx.setFillColor(palette[second % palette.count])
        ctx.fill(rect)

        // rule 3 — border on all four edges
        ctx.setStrokeColor(borderColor)
        ctx.setLineWidth(borderWidth)
        ctx.stroke(rect.insetBy(dx: borderWidth / 2, dy: borderWidth / 2))

        // rule 4 — centred circle, square in the intended display aspect
        let displayedDiameter = min(CGFloat(width) * pixelAspect, CGFloat(height)) * 0.5
        let storedWidth = displayedDiameter / pixelAspect
        let circle = CGRect(
            x: (CGFloat(width) - storedWidth) / 2,
            y: (CGFloat(height) - displayedDiameter) / 2,
            width: storedWidth, height: displayedDiameter)
        ctx.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.setLineWidth(3)
        ctx.strokeEllipse(in: circle)

        // rule 2 — the second's index burned in
        drawNumeral(second, in: ctx, bounds: rect)
    }

    private static func drawNumeral(_ value: Int, in ctx: CGContext, bounds: CGRect) {
        let text = "\(value)" as CFString
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, bounds.height * 0.35, nil)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(red: 0, green: 0, blue: 0, alpha: 1),
        ]
        let attributed = CFAttributedStringCreate(nil, text, attributes as CFDictionary)!
        let line = CTLineCreateWithAttributedString(attributed)
        let textBounds = CTLineGetBoundsWithOptions(line, [])
        ctx.textPosition = CGPoint(
            x: bounds.midX - textBounds.width / 2,
            y: bounds.midY - textBounds.height / 2)
        CTLineDraw(line, ctx)
    }
}
