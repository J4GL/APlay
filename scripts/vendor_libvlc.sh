#!/bin/bash
# impl: VLC-001 rules 1-4 — vendor libvlc from an installed VLC.app into Vendor/libvlc/
#
# Copies only what Play needs: the two dylibs, the headers, and a curated
# allowlist of plugins (VLC-001 rule 2). An allowlist, not an exclusion list —
# a new VLC release that adds plugins must not silently grow the bundle.
set -euo pipefail

VLC_APP="${VLC_APP:-/Applications/VLC.app}"
SRC="$VLC_APP/Contents/MacOS"
DEST="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/Vendor/libvlc"

die() { echo "vendor_libvlc: $*" >&2; exit 1; }

# --- rule 3: fail loudly on a bad source ------------------------------------
[ -d "$VLC_APP" ] || die "no VLC.app at $VLC_APP (set VLC_APP=/path/to/VLC.app)"
[ -d "$SRC/plugins" ] || die "no plugins dir at $SRC/plugins"
[ -f "$SRC/lib/libvlc.5.dylib" ] || die "no libvlc.5.dylib at $SRC/lib"
[ -d "$SRC/include/vlc" ] || die "no headers at $SRC/include/vlc"

arch="$(file -b "$SRC/lib/libvlc.5.dylib")"
case "$arch" in
  *arm64*) ;;
  *) die "libvlc.5.dylib is not arm64: $arch" ;;
esac

ver="$("$SRC/../MacOS/VLC" --version 2>/dev/null | head -1 | sed -n 's/^VLC version \([0-9][0-9.]*\).*/\1/p')"
case "$ver" in
  3.*) ;;
  *) die "unsupported VLC version '${ver:-unknown}' (need 3.x)" ;;
esac

# --- rule 2: the plugin allowlist -------------------------------------------
# Grouped by VLC module category. Every entry earns its place for LOCAL FILE
# playback of the containers in FormatCatalog (MEDIA-002 rule 2), plus
# subtitles (TRACK-001) and audio track selection (TRACK-003).
#
# To add one back: put it in the right group with a comment saying which file
# or feature needed it, and re-run VLC-001-H4.
PLUGINS=(
  # access — local files only. No network, no optical disc, no capture.
  filesystem imem

  # stream_filter — read caching and container preprocessing
  cache_read cache_block prefetch skiptags inflate decomp record

  # demux — the containers Play declares it can open
  mp4 mkv avi asf ps ts es ogg flacsys h26x mpgv nsv nuv pva ty
  rawvid rawaud rawdv wav aiff au caf voc xa mjpeg image diracsys
  subtitle directory_demux playlist adf demux_stl es

  # codec — video. avcodec covers the great majority; the rest are formats
  # avcodec declines or that macOS accelerates.
  avcodec videotoolbox dav1d cvpx jpeg png rawvideo cdg

  # codec — audio. A52/DTS/AAC decoding lives inside avcodec in VLC 3.0.x;
  # only their packetizers exist as standalone plugins (see below).
  faad flac opus vorbis speex mpg123 adpcm araw g711 lpcm
  uleaddvaudio aes3

  # codec — subtitles. Every renderer FormatCatalog's sidecar list implies.
  subsdec subsusf subsdelay webvtt ttml substx3g spudec dvbsub svcdsub
  cvdsub textst stl kate aribsub cc scte18 scte27 telx

  # packetizer — required between demuxer and decoder; all small
  packetizer_copy packetizer_h264 packetizer_hevc packetizer_mpeg4video
  packetizer_mpeg4audio packetizer_mpegvideo packetizer_mpegaudio
  packetizer_a52 packetizer_dts packetizer_flac packetizer_mlp
  packetizer_vc1 packetizer_av1 packetizer_dirac h26x

  # video_output — macOS. caopengllayer is what set_nsobject renders into.
  vout_macosx caopengllayer glconv_cvpx vdummy

  # video_chroma / video_filter — format conversion and rotation metadata
  swscale i420_rgb i420_yuy2 i422_i420 i422_yuy2 yuy2_i420 yuy2_i422
  i420_nv12 i420_10_p010 grey_yuv rv32 yuvp chain scale
  deinterlace transform

  # text_renderer — subtitle rendering. libass honours ASS/SSA styling.
  freetype libass

  # audio_output — CoreAudio
  auhal adummy

  # audio_filter — mixing, resampling, format conversion
  audio_format float_mixer integer_mixer simple_channel_mixer
  trivial_channel_mixer dolby_surround_decoder headphone_channel_mixer
  mono remap scaletempo speex_resampler ugly_resampler tospdif spdif gain

  # misc — xml is required by the TTML/USF subtitle parsers
  xml
)

# --- copy --------------------------------------------------------------------
echo "vendor_libvlc: source $VLC_APP (VLC $ver, arm64)"
rm -rf "$DEST/lib" "$DEST/plugins"
mkdir -p "$DEST/lib" "$DEST/plugins" "$DEST/include"

# headers (committed to git)
rm -rf "$DEST/include/vlc"
cp -R "$SRC/include/vlc" "$DEST/include/vlc"

# dylibs, preserving the versioned symlinks
cp -a "$SRC/lib/libvlc.5.dylib" "$SRC/lib/libvlccore.9.dylib" "$DEST/lib/"
ln -sf libvlc.5.dylib     "$DEST/lib/libvlc.dylib"
ln -sf libvlccore.9.dylib "$DEST/lib/libvlccore.dylib"

copied=0
missing=()
for p in "${PLUGINS[@]}"; do
  f="$SRC/plugins/lib${p}_plugin.dylib"
  if [ -f "$f" ]; then
    # Some names appear twice across groups (h26x, es); skip if already copied.
    [ -f "$DEST/plugins/lib${p}_plugin.dylib" ] && continue
    cp "$f" "$DEST/plugins/"
    copied=$((copied + 1))
  else
    missing+=("$p")
  fi
done

# rule 2: these must never be copied, whatever the allowlist says
for banned in macosx osx_notifications; do
  rm -f "$DEST/plugins/lib${banned}_plugin.dylib"
done
rm -f "$DEST/plugins/plugins.dat"

if [ ${#missing[@]} -gt 0 ]; then
  echo "vendor_libvlc: WARNING ${#missing[@]} allowlisted plugin(s) not found in this VLC:" >&2
  printf '  %s\n' "${missing[@]}" >&2
fi

size_mb=$(( $(find "$DEST/plugins" "$DEST/lib" -type f -exec wc -c {} + | tail -1 | awk '{print $1}') / 1048576 ))
echo "vendor_libvlc: copied $copied plugins + 2 dylibs = ${size_mb} MB -> $DEST"
echo "vendor_libvlc: ok"
