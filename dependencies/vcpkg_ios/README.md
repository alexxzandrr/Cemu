# vcpkg_ios

Dependency manifest and triplet for the iPadOS (WiiPad) build. Kept separate from the root
`vcpkg.json` so desktop builds are unaffected.

Same `builtin-baseline` as the root manifest, minus desktop-only packages:
wxWidgets, SDL3, libusb, tiff (wx only), dbus (Linux), glslang (Vulkan only).
Selected with `-DVCPKG_MANIFEST_DIR=dependencies/vcpkg_ios -DVCPKG_OVERLAY_TRIPLETS=dependencies/vcpkg_ios/triplets -DVCPKG_TARGET_TRIPLET=arm64-ios-wiipad`.
