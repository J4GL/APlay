#!/bin/bash
# impl: ICON-001 rules 2-4 — JPEG artwork -> transparent 1024 master PNG ->
# iconset -> AppIcon.icns, with a self-check that fails the run if the corners
# are not transparent. Deterministic, no network.
#
# Usage: scripts/make_app_icon.sh [source.jpeg]
# Env: SWIFT_TIMEOUT / SIPS_TIMEOUT / ICONUTIL_TIMEOUT (defaults below)
#
# No caller in the build: runs by hand when the artwork changes. Both build
# drivers consume the committed AppIcon.icns (ICON-001 rule 5).
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT="$PWD"
SRC="${1:-$ROOT/assets/app-icon/AppIcon-source.jpeg}"
MASTER="$ROOT/assets/app-icon/AppIcon-1024.png"
ICNS="$ROOT/Sources/Play/Resources/AppIcon.icns"
SWIFT_TIMEOUT="${SWIFT_TIMEOUT:-300}"
SIPS_TIMEOUT="${SIPS_TIMEOUT:-120}"
ICONUTIL_TIMEOUT="${ICONUTIL_TIMEOUT:-120}"

die() { echo "make_app_icon: $*" >&2; exit 1; }

[ -f "$SRC" ] || die "no artwork source at $SRC"
for t in swiftc sips iconutil; do
  command -v "$t" >/dev/null 2>&1 || die "missing required tool: $t"
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/appicon.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

echo "make_app_icon: src: $SRC"
sips -g pixelWidth -g pixelHeight "$SRC"

# --- step 1: flood-fill corner removal + square pad -> 551x551 straight-RGBA PNG
cat > "$WORK/process.swift" <<'SWIFTEOF'
import AppKit
import Foundation

// impl: ICON-001 rules 2-3 — border-connected flood fill + unblended fringe.
let T0 = 40.0    // fill tolerance (Euclidean in RGB from the corner color)
let T2 = 220.0   // beyond this a near-border pixel is opaque, not fringe
let ADEN = 225.0 // linear alpha denominator: dist(edge dark ~115, bg ~245)

func fail(_ msg: String) -> Never { fputs("make_app_icon: \(msg)\n", stderr); exit(1) }

func readStraight(_ cg: CGImage) -> (w: Int, h: Int, px: [UInt8]) {
    let w = cg.width, h = cg.height
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
        bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                 | CGBitmapInfo.byteOrder32Big.rawValue) else { fail("no ctx") }
    ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
    ctx.interpolationQuality = .high
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    guard let data = ctx.data else { fail("no pixels") }
    let raw = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
    var out = [UInt8](repeating: 0, count: w * h * 4)
    for i in 0 ..< w * h {
        let a = Int(raw[i * 4 + 3])
        if a == 255 {
            out[i*4] = raw[i*4]; out[i*4+1] = raw[i*4+1]
            out[i*4+2] = raw[i*4+2]; out[i*4+3] = 255
        } else if a > 0 {
            out[i*4] = UInt8(min(255, Int(raw[i*4]) * 255 / a))
            out[i*4+1] = UInt8(min(255, Int(raw[i*4+1]) * 255 / a))
            out[i*4+2] = UInt8(min(255, Int(raw[i*4+2]) * 255 / a))
            out[i*4+3] = UInt8(a)
        }
    }
    return (w, h, out)
}

func loadCG(_ path: String) -> CGImage {
    let url = URL(fileURLWithPath: path) as CFURL
    guard let src = CGImageSourceCreateWithURL(url, nil),
          let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        fail("cannot decode \(path)")
    }
    return cg
}

func writePNG(w: Int, h: Int, px: [UInt8], to path: String) {
    let data = Data(px)
    guard let prov = CGDataProvider(data: data as CFData),
          let img = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
              bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue
                                     | CGBitmapInfo.byteOrder32Big.rawValue),
              provider: prov, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
          let dst = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
              "public.png" as CFString, 1, nil) else { fail("cannot encode \(path)") }
    CGImageDestinationAddImage(dst, img, nil)
    guard CGImageDestinationFinalize(dst) else { fail("cannot write \(path)") }
}

func dist(_ px: [UInt8], _ i: Int, _ bg: (Double, Double, Double)) -> Double {
    let dr = Double(px[i*4]) - bg.0
    let dg = Double(px[i*4+1]) - bg.1
    let db = Double(px[i*4+2]) - bg.2
    return (dr * dr + dg * dg + db * db).squareRoot()
}

// Inverse of the over operator for a flat background: c = a*fg + (1-a)*bg.
func unblend(_ c: UInt8, _ b: Double, _ ia: Double, _ a: Double) -> UInt8 {
    let v = (Double(c) - ia * b) / a
    if v <= 0 { return 0 }
    if v >= 255 { return 255 }
    return UInt8(v)
}

// Convert mode: flood-fill the border-connected background, unblend the fringe,
// square-pad, write PNG. Prints stats for the record.
func convert(src: String, dst: String) {
    let (w, h, initial) = readStraight(loadCG(src))
    var px = initial
    // Corner color = mean of four 6x6 patches (ICON-001 rule 1).
    var sr = 0.0, sg = 0.0, sb = 0.0
    let corners = [(0, 0), (w - 6, 0), (0, h - 6), (w - 6, h - 6)]
    for (cx, cy) in corners {
        for y in cy ..< cy + 6 {
            for x in cx ..< cx + 6 {
                let i = y * w + x
                sr += Double(px[i*4]); sg += Double(px[i*4+1]); sb += Double(px[i*4+2])
            }
        }
    }
    let bg = (sr / 144.0, sg / 144.0, sb / 144.0)
    print(String(format: "process: %@x%@ bg=%.1f,%.1f,%.1f", "\(w)", "\(h)", bg.0, bg.1, bg.2))
    var top = 0.0, bot = 0.0
    for x in 0 ..< w {
        for y in 0 ..< 10 {
            let i = (y * w + x) * 4
            top += Double(px[i]) + Double(px[i+1]) + Double(px[i+2])
        }
        for y in h - 10 ..< h {
            let i = (y * w + x) * 4
            bot += Double(px[i]) + Double(px[i+1]) + Double(px[i+2])
        }
    }
    print(String(format: "process: top-rows mean=%.1f bottom-rows mean=%.1f", top/Double(w*10*3), bot/Double(w*10*3)))

    let n = w * h
    var filled = [Bool](repeating: false, count: n)
    var stack = [Int]()
    func seed(_ i: Int) {
        if !filled[i] && dist(px, i, bg) <= T0 { filled[i] = true; stack.append(i) }
    }
    for x in 0 ..< w { seed(x); seed((h - 1) * w + x) }
    for y in 0 ..< h { seed(y * w); seed(y * w + w - 1) }
    while let i = stack.popLast() {
        let x = i % w, y = i / w
        if x > 0 { seed(i - 1) }
        if x < w - 1 { seed(i + 1) }
        if y > 0 { seed(i - w) }
        if y < h - 1 { seed(i + w) }
    }
    var filledCount = 0
    // Fringe: unfilled pixels within Chebyshev 2 of the fill (ICON-001 rule 3).
    var fringe = [Bool](repeating: false, count: n)
    for y in 0 ..< h {
        for x in 0 ..< w {
            let i = y * w + x
            if filled[i] { filledCount += 1; continue }
        }
    }
    for y in 0 ..< h {
        for x in 0 ..< w {
            if !filled[y * w + x] { continue }
            for dy in -2 ... 2 {
                for dx in -2 ... 2 {
                    let nx = x + dx, ny = y + dy
                    if nx < 0 || ny < 0 || nx >= w || ny >= h { continue }
                    fringe[ny * w + nx] = true
                }
            }
        }
    }
    var fringeCount = 0
    for i in 0 ..< n {
        if filled[i] {
            px[i*4] = 0; px[i*4+1] = 0; px[i*4+2] = 0; px[i*4+3] = 0
        } else if fringe[i] {
            let d = dist(px, i, bg)
            if d < T2 {
                fringeCount += 1
                let a = d / ADEN
                if a < 0.02 {
                    px[i*4] = 0; px[i*4+1] = 0; px[i*4+2] = 0; px[i*4+3] = 0
                } else {
                    let ia = 1.0 - a
                    px[i*4] = unblend(px[i*4], bg.0, ia, a)
                    px[i*4+1] = unblend(px[i*4+1], bg.1, ia, a)
                    px[i*4+2] = unblend(px[i*4+2], bg.2, ia, a)
                    let ai = a * 255.0
                    px[i*4+3] = ai >= 255 ? 255 : UInt8(ai)
                }
            }
        }
    }
    print("process: filled=\(filledCount) fringe=\(fringeCount) total=\(n)")

    // impl: ICON-001 rule 3b — the source photo carries a soft, wide shadow
    // gradient along its top edge only (bottom measured clean); at some
    // top-edge columns it fades from bg toward tile-body gray over 10+ px,
    // far wider than the T0/T2 model assumes, and no fixed threshold removes
    // it without also eating real tile gradient. The bottom two corners are
    // clean (same measured tile, no shadow), so each top corner's alpha is
    // replaced by its own bottom corner's alpha, vertically mirrored — same
    // radius, same shape, by construction — while keeping this pixel's own
    // photographed color. CORNER_FIX must clear the triangle's bounding box
    // (measured top ~178 px) with margin; the corner radius measured ~115 px.
    let CORNER_FIX = 150
    for dy in 0 ..< CORNER_FIX {
        let srcY = h - 1 - dy
        for dx in 0 ..< CORNER_FIX {
            let mirroredAlpha = px[(srcY * w + dx) * 4 + 3]
            let i = (dy * w + dx) * 4
            if mirroredAlpha == 0 {
                px[i] = 0; px[i+1] = 0; px[i+2] = 0; px[i+3] = 0
            } else {
                px[i] = initial[i]; px[i+1] = initial[i+1]; px[i+2] = initial[i+2]
                px[i+3] = mirroredAlpha
            }
        }
        for dx in 0 ..< CORNER_FIX {
            let x = w - 1 - dx
            let mirroredAlpha = px[(srcY * w + x) * 4 + 3]
            let i = (dy * w + x) * 4
            if mirroredAlpha == 0 {
                px[i] = 0; px[i+1] = 0; px[i+2] = 0; px[i+3] = 0
            } else {
                px[i] = initial[i]; px[i+1] = initial[i+1]; px[i+2] = initial[i+2]
                px[i+3] = mirroredAlpha
            }
        }
    }
    print("process: top corners repaired from bottom-corner mirror, box=\(CORNER_FIX)")

    // Square-pad with transparent rows (ICON-001 rule 4).
    let s = max(w, h)
    var sq = [UInt8](repeating: 0, count: s * s * 4)
    let yOff = (s - h) / 2, xOff = (s - w) / 2
    for y in 0 ..< h {
        for x in 0 ..< w {
            let si = ((y + yOff) * s + x + xOff) * 4, di = (y * w + x) * 4
            sq[si] = px[di]; sq[si+1] = px[di+1]; sq[si+2] = px[di+2]; sq[si+3] = px[di+3]
        }
    }
    writePNG(w: s, h: s, px: sq, to: dst)
}

// Verify mode: corners transparent, center opaque and bright. Orientation-free.
func verify(path: String, size: Int, cornerMax: Int) {
    guard let img = NSImage(contentsOfFile: path),
          let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        fail("cannot decode \(path)")
    }
    var rect = NSRect(origin: .zero, size: NSSize(width: size, height: size))
    guard let sized = img.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
        fail("no \(size)px representation in \(path)")
    }
    _ = cg
    let (w, h, px) = readStraight(sized)
    func alpha(_ x: Int, _ y: Int) -> Int { Int(px[(y * w + x) * 4 + 3]) }
    let c = [alpha(0, 0), alpha(w - 1, 0), alpha(0, h - 1), alpha(w - 1, h - 1)]
    print("verify: \(path) @\(w)x\(h) corners=\(c)")
    if c.max()! > cornerMax { fail("corners not transparent in \(path): \(c)") }
    var sum = 0, amin = 255, cnt = 0
    for y in h/2 - 50 ..< h/2 + 50 {
        for x in w/2 - 50 ..< w/2 + 50 {
            let i = (y * w + x) * 4
            amin = min(amin, Int(px[i+3]))
            sum += Int(px[i]) + Int(px[i+1]) + Int(px[i+2]); cnt += 1
        }
    }
    let mean = Double(sum) / Double(cnt * 3)
    print(String(format: "verify: center minAlpha=%d mean=%.1f", amin, mean))
    if amin < 250 || mean < 240 { fail("triangle damaged in \(path)") }
    print("verify: OK \(path)")
}

let args = CommandLine.arguments
if args.count == 4 && args[1] == "--convert" {
    convert(src: args[2], dst: args[3])
} else if args.count == 5 && args[1] == "--verify" {
    verify(path: args[2], size: Int(args[3])!, cornerMax: Int(args[4])!)
} else {
    fputs("usage: process --convert <src> <dst.png> | --verify <file> <size> <cornerMax>\n", stderr)
    exit(2)
}
SWIFTEOF

echo "make_app_icon: compiling processor"
# impl: AGENTS.md rule 7 — every command carries a timeout.
timeout "$SWIFT_TIMEOUT" swiftc -module-cache-path "$WORK/ModuleCache" \
  -o "$WORK/process" "$WORK/process.swift" -framework AppKit

echo "make_app_icon: corner removal (ICON-001 rules 2-3)"
timeout "$SWIFT_TIMEOUT" "$WORK/process" --convert "$SRC" "$WORK/square.png"
timeout "$SWIFT_TIMEOUT" "$WORK/process" --verify "$WORK/square.png" 551 0

echo "make_app_icon: master 1024 (ICON-001 rule 4)"
timeout "$SIPS_TIMEOUT" sips -z 1024 1024 "$WORK/square.png" --out "$WORK/master.png" >/dev/null
timeout "$SWIFT_TIMEOUT" "$WORK/process" --verify "$WORK/master.png" 1024 0
mv -f "$WORK/master.png" "$MASTER"

echo "make_app_icon: iconset -> icns"
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
sizes="16:icon_16x16.png 32:icon_16x16@2x.png 32:icon_32x32.png 64:icon_32x32@2x.png \
128:icon_128x128.png 256:icon_128x128@2x.png 256:icon_256x256.png 512:icon_256x256@2x.png \
512:icon_512x512.png 1024:icon_512x512@2x.png"
# shellcheck disable=SC2086
for spec in $sizes; do
  px="${spec%%:*}"; name="${spec##*:}"
  timeout "$SIPS_TIMEOUT" sips -z "$px" "$px" "$MASTER" --out "$ICONSET/$name" >/dev/null
done
timeout "$ICONUTIL_TIMEOUT" iconutil -c icns "$ICONSET" -o "$WORK/AppIcon.icns"
timeout "$SWIFT_TIMEOUT" "$WORK/process" --verify "$WORK/AppIcon.icns" 1024 8
mv -f "$WORK/AppIcon.icns" "$ICNS"

echo
echo "make_app_icon: OK"
ls -la "$MASTER" "$ICNS"
