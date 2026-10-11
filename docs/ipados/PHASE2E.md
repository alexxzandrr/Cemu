# Phase 2E — Full-screen game view, translucent on-screen controls

Branch `phase2`. The game now fills the screen and the GamePad controls sit over it, instead of a 480×270 view with
the controls beside it. Boot path, interpreter, renderer, audio and motion unchanged.

## Cemu path (reused)

Desktop Cemu resizes in two places: `MainWindow::OnSizeEvent` writes the client size into the window info
(`width/height`, `phys_width/phys_height`, `dpi_scale`, all atomics read by the GPU thread), and
`MetalCanvas::OnResize` calls `MetalRenderer::ResizeLayer` (CAMetalLayer drawable size). Everything downstream reads
the window info: output scaling with kept aspect ratio and letterboxing
(`LatteRenderTarget_getScreenImageArea`), ImGui overlays, and the touch → GamePad-touchscreen mapping.

## WiiPad

| Piece | What |
| --- | --- |
| `src/ios/CemuBridge.h/.mm` | `gameViewDidResize:` — the two desktop steps above for the host view; main thread, no-op before the renderer exists or when the size is unchanged; logs `game view resized: W×H pt (W×H px)` |
| `app/WiiPad/Sources/ContentView.swift` | root `ZStack`: the Metal host view is always its first child and full screen (`ignoresSafeArea`), so SwiftUI never recreates it; the setup panel covers it before launch, the GamePad overlay while a title runs. `GameSurfaceView.layoutSubviews` calls `gameViewDidResize:` (rotation, Split View, Stage Manager). While playing: status bar and home indicator hidden, edge swipes deferred (a second swipe opens Control Center / goes Home). |
| `app/WiiPad/Sources/GamePadControls.swift` | `GamePadOverlay`: GamePad layout — ZL/L and R/ZR in the top corners, left stick over the D-pad, right stick over X/A/B/Y, − and + at the bottom centre; sizes scale with the screen (tuned for 11", 0.8–1.3×). Toolbar at the top centre: Pad/TV view, Recenter (tilt), control opacity (30/55/80/100 %, default 55 %), hide/show controls. Opacity persists (`UserDefaults`); controls always start shown. Hiding keeps the controls in the view tree (invisible, disabled, not hit-testable) so the overlay's layout over the game view is identical in both states, and Show sits where Hide was; a held button or stick is released when hidden. |

Touches that miss a control fall through to the game view and become GamePad touchscreen input, mapped through the
letterboxed image area as on desktop, so "Pad view" still lines up touches with the GamePad screen.

No upstream Cemu file changed.

## Fix: "Show controls" did not respond (e7e2ea8)

Device test: after Hide, tapping "Show controls" did nothing, and the hidden state was persisted, so it stayed hidden
after relaunch. In that build hiding removed the controls and the other toolbar items from the view tree, so the
lone Show button sat in a different overlay layout over the game view than the working Hide button. Now nothing is
removed (only visibility and hit testing change) and the hidden state is no longer stored.

## Log lines (`WiiPad.log`)

`game view resized: ...`, `on-screen controls hidden` / `shown`, `GamePad screen in game view: on` / `off`.

## Known limitations

- Controls overlap the picture (by design, translucent); no layout editor yet.
- Single-touch on the game view (as in 2B).

## Cemu notifications moved below the toolbar

Cemu's notifications ("Compiled N new shaders…") default to the top left, where they covered ZL/L. Every corner and
centre position has an on-screen control, so at title launch WiiPad sets `notification.position` to top centre (in
memory) and `LatteOverlay_setTopInset` (iOS-only, `LatteOverlay.cpp`) moves top-anchored overlays 60 pt down, below the
toolbar, into the letterbox bar of a landscape iPad.
