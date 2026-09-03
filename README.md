# APlay

A borderless, minimalist video player for macOS, built directly on **libvlc**.

No titlebar. No traffic lights. No menus over the picture. Just the film, in a window shaped like
it, with controls that fade in when you move the mouse and disappear when you don't.

## Why libvlc

VLC's decoding stack is the reason this exists rather than being a thin wrapper over AVKit. It plays
MKV, ASS/SSA subtitles, VobSub, and the codec-and-container combinations AVFoundation declines —
the old files you actually have. `libvlc` is the C library underneath VLC.app, and APlay links it
directly.

libvlc and its plugins are **bundled inside the app** (~83 MB), so APlay runs on a Mac with no VLC
installed.

## What it does

- **Borderless window** — chromeless, rounded, resize from any edge, sized to the film's true
  display aspect ratio (anamorphic included). Drag it from **any** surface that is not a control,
  the HUD's own backdrop included; an 8 pt dead band around each control means missing a small
  button does not fling the window across the desktop
- **Open anything** — ⌘O, drag and drop, Finder "Open With", or a command-line path
- **Playback** — play/pause, scrub with a hover time preview, keyboard seek, 0–125 % volume with
  headroom for quiet dialogue, and per-file resume offered as a toast rather than a silent jump
- **Subtitles** — embedded tracks, dropped `.srt`/`.ass`, automatic sidecar discovery, delay
  adjustment for files that run out of sync
- **Audio tracks** — dual-audio and commentary selection, with channel layout shown where it
  distinguishes tracks
- **Queue** — drop a folder, play it through, with an overlay list you can reorder
- **Menu bar** — every command is discoverable in File / Playback / Audio / Subtitle / Window, with
  the ⌘ shortcuts shown beside them; the track menus list what the current file actually contains
- **Language preferences** (⌘,) — an ordered list of two-letter language codes for audio and for
  subtitles, kept separate, so you can watch in the original language and read your own.
  **Each has a name filter that breaks a tie between two tracks of the same language** ("Français"
  versus "Français forced"). The filter only *ranks*: it never causes a language to be skipped.

Deliberately **not** included: playback speed, frame stepping, A-B loop, streaming, casting, or an
equalizer. Subtitle typography (font, size, colour) is also out of scope, settings window or not.

## Requirements

- macOS 26.5+, Apple Silicon
- Xcode 26.6 / Swift 6.3
- VLC.app 3.0.x installed **at build time only** (the payload is copied out of it)
- `xcodegen` (`brew install xcodegen`)
- An Apple Developer account — builds are signed with `Apple Development`, Team `V786D35WNB`,
  under the hardened runtime and without the sandbox

## Build

```bash
scripts/vendor_libvlc.sh && xcodegen generate && scripts/build.sh
```

`vendor_libvlc.sh` copies libvlc, libvlccore and 338 plugins out of `/Applications/VLC.app` into
`Vendor/libvlc/`. That payload is gitignored — it is ~83 MB and fully reproducible from the script,
so it is not in version control. Only the headers are committed.

## Test

E2E tests are XCUITest. They assert against two oracles: element-scoped screenshots, and a
structured JSONL log at `~/Library/Logs/APlay/`. Media fixtures are generated with `AVAssetWriter`
and never committed — each fixture second is a known flat colour, which is what makes "did that seek
land at 7 s?" answerable by looking at the picture.

Running them needs the XCTest/XCUITest runners, which ship only with full Xcode (`xcodebuild test`)
— not available from the Command Line Tools alone, so there is no test script in this checkout.
`scripts/build.sh` and `scripts/make_fixtures.sh` work without Xcode.

## Project status

| Phase | State |
|---|---|
| Specifications (26 specs, 152 scenarios) | **written, lint-clean** |
| Platform, window, media, playback, tracks, queue, HUD | **built** |
| Menu bar (CTRL-004), language preferences (PREF-001), drag-anywhere (WIN-001 r9) | **built** |
| Aspect-ratio lock — resizing never changes the picture's shape (WIN-003 r5, r13-15) | **built** |
| Failure banner (MEDIA-002 r7, r9-11) | **built** |
| Resume position (PLAY-004) | not started |
| Opening size and geometry persistence (WIN-003 r3-4, r8-11) | not started |
| Notarised distribution (NOTARY-001) | **built** — signed, notarized, stapled DMG on [GitHub Releases](https://github.com/J4GL/APlay/releases) |

## Credits and licence

APlay is built on **libVLC** by the [VideoLAN](https://www.videolan.org) project — VLC 3.0.23
"Vetinari". libVLC is licensed under the **LGPL v2.1 or later**; APlay links it dynamically and ships
the libraries unmodified. VLC's source is at <https://code.videolan.org/videolan/vlc>, and the LGPL
text at <https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html>.

APlay's own code is licensed under the same terms — **LGPL v2.1 or later** (see [`LICENSE`](LICENSE)).
