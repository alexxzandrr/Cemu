# src/ios

iPadOS platform layer for Cemu. Empty in Phase 1A.

Planned contents (Phase 1B onward), kept here so upstream Cemu files stay untouched where possible:

- `MetalLayerUIKit.mm` — UIKit implementation of `CreateMetalLayer()` (macOS uses `Renderer/Metal/MetalLayer.mm`)
- `IOSWindowSystem.mm` — implementation of `gui/interface/WindowSystem.h`
- `CemuBridge.h/.mm` — the small Objective-C++ API the SwiftUI app calls

See `docs/ipados/` for decisions.
