# Phase 4 — iPhone Duo and dual screens

Branch `phase2`. WiiPad becomes a universal app (iPhone and iPad) with the focus on iPhone Duo: the Wii U's two
screens (TV and GamePad) shown at the same time, laid out by how the Duo is folded, the way Delta lays out the
Nintendo DS's two screens.

## Layouts

| Duo pose / screen shape | TV image | GamePad screen | Controls |
| --- | --- | --- | --- |
| Folded like a laptop (fold across the screen) | top half | bottom half, centred | around the GamePad screen: sticks + D-pad left, sticks + X/A/B/Y right, shoulders in the corners, − / + below |
| Folded like a book (fold down the middle) | left half | right half | translucent, over both |
| Open flat or closed (outer display), wide screen | full screen | (Pad view switch) | translucent, over the TV image (Phase 2E full-screen mode) |
| Open flat, held tall; iPad in portrait | top half | bottom half | as in the laptop layout, split in the middle |

"Screens" in the toolbar: Automatic (the table), TV only, TV + GamePad (also side by side on a wide screen without a
fold, e.g. iPad in landscape).

## How

| Piece | What |
| --- | --- |
| `project.yml`, `Info.plist` | `TARGETED_DEVICE_FAMILY` 1,2; iPhone orientations |
| `.github/workflows/ios-build.yml` | default runner `xcode-27`; selects the newest installed Xcode 27.1+. The iOS 27.1 SDK gives the full Duo screens (older SDKs run letterboxed) and the fold API |
| `app/WiiPad/Sources/DualScreen.swift` | `ScreenArrangement` (pure layout maths from the size and the fold), `activeFold(in:)` (`GeometryProxy.reservedRegions(kind: .division)`, iOS 27.1), `PadHostView` (second Metal view), `DualControlsPanel`, `ScreensMenu` |
| `ContentView.swift` | one full-screen `GeometryReader` places the TV view, GamePad view and controls; the TV view keeps its identity (Cemu's CAMetalLayer stays attached), only its frame changes |
| `CemuBridge` | `attachGamePadView:` / `detachGamePadView` / `gamePadViewDidResize:` / `setGamePadViewTouchDown:x:y:` — Cemu's existing separate GamePad window (desktop `PadViewFrame` + `MetalCanvas(is_main_window = false)`): `window_pad`, `pad_open`, `pad_*` sizes, `MetalRenderer::InitializeLayer/ResizeLayer/ShutdownLayer(…, false)` |
| `WiiPadTouchController` | touches on the GamePad view go to `m_pad_touch` in pad-window pixels (Cemu maps them onto the GamePad image) |

No change to Cemu's core or renderer: the separate GamePad window is an existing desktop feature.

## Known limits

- Attaching or detaching the GamePad view while a title runs does what the desktop does when its GamePad window is
  opened or closed mid-game; this happens only when the layout changes (folding, rotating, the Screens menu).
- The fold API needs the iOS 27.1 SDK on CI. Without a fold (older SDK, iPad), the layout still follows the screen shape.
- Closing the Duo does not pause the game (Delta pauses DS games); not done yet.

## Log lines (`WiiPad.log`)

- `screens: stacked (fold at y …-…), TV …x…, GamePad …x…` on every layout change
- `GamePad view attached: …x… pt (…x… px)`, `GamePad view resized: …`, `GamePad view detached`
- `input: touch down at (…) px of …x… on the GamePad view -> GamePad touchscreen`
