// impl: VLC-001 — Swift <-> libvlc C interop.
// HEADER_SEARCH_PATHS points at Vendor/libvlc/include (project.yml).
//
// The umbrella header is imported rather than the individual ones: libvlc's
// per-feature headers are not self-contained (libvlc_media_player.h uses
// libvlc_renderer_item_t without including its declaration), so importing them
// piecemeal fails to build the bridging PCH.

#import <vlc/vlc.h>
