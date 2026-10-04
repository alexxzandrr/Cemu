# Phase 1A — Build pipeline and first device install

Status: workflow written and linted locally; **not yet run on GitHub** (see "Verification status").

Goal: Windows PC → GitHub → GitHub Actions (macOS arm64) → Xcode → unsigned arm64 iPadOS `.ipa` → artifact → sideload onto the M3 iPad Air.

## What was added

| Path | Purpose |
| --- | --- |
| `.github/workflows/ios-build.yml` | Builds the app on `macos-26` (Apple Silicon, Xcode 26.x, GA). Optional Xcode 27 preview job via manual run. Uploads `CemuIOS-unsigned-<runner>.ipa` and the build log. |
| `app/CemuIOS/project.yml` | XcodeGen spec. The `.xcodeproj` is generated in CI and never committed, so the project is editable as text from Windows. |
| `app/CemuIOS/Sources/*.swift` | SwiftUI app showing "Cemu iPadOS / Build system online." |
| `app/CemuIOS/Sources/BuildInfo.{h,mm}` | Objective-C++ (C++20) probe called from Swift. Proves the Swift → Obj-C++ → C++ path the future `CemuBridge` will use. |
| `app/CemuIOS/Sources/Info.plist` | iPad-only, arm64 + Metal required, Files-app document sharing enabled (for logs later). |
| `src/ios/README.md` | Placeholder for iPadOS platform code (UIKit Metal layer, `WindowSystem`, bridge). |

No upstream Cemu file was modified.

## Decisions

- **Runner:** `macos-26` (Apple Silicon, generally available, free for public repositories). The `xcode-27` image is still a *public preview*, with reported queueing and a missing Metal toolchain, so it is opt-in (`Run workflow` → "Also build on the Xcode 27 preview runner"). Apps built with the iOS 26 SDK run on iPadOS 27.
- **Deployment target:** iOS 16.0, not 27. iOS 16 is where Metal 3 (mesh shaders, used by Cemu's geometry-shader path) arrived; nothing in the shell needs newer. Can be raised later if a dependency requires it.
- **Device family:** iPad only (`TARGETED_DEVICE_FAMILY = 2`), arm64 only.
- **Project generation:** XcodeGen (preinstalled on the runner; the workflow falls back to Homebrew).
- **Workflow scope:** triggers only on changes under `app/`, `src/ios/` or the workflow itself.
- **Upstream workflows:** `build.yml`, `build_check.yml`, `generate_pot.yml` remain in the tree (to keep merges clean) but should be **disabled in the fork's Actions tab**, otherwise every push runs full desktop builds.

## Unsigned build: what CI produces

- `xcodebuild ... CODE_SIGNING_ALLOWED=NO` produces an unsigned `CemuIOS.app` for `iphoneos`/arm64. No Apple account, certificate or secret is involved.
- CI zips it as `Payload/CemuIOS.app` → `CemuIOS-unsigned-macos-26.ipa`. An `.ipa` is just that zip layout.
- The packaging step prints `lipo -info`, `LC_BUILD_VERSION` (min OS / SDK) and `codesign -dv` (expected: "not signed") so the artifact can be checked from the log.
- **An unsigned app cannot run on iPadOS.** It must be signed with a certificate + provisioning profile that includes the device. That happens on the Windows PC during sideloading.

## Installing on the iPad from Windows (Sideloadly)

1. Download the `.ipa` from the workflow run's *Artifacts* section (GitHub wraps it in a `.zip`; extract it).
2. On Windows, install iTunes and iCloud from Apple's website (not the Microsoft Store versions — Sideloadly requires the web installers), then Sideloadly.
3. Connect the iPad by USB, trust the PC.
4. On the iPad: Settings → Privacy & Security → **Developer Mode** → on, then reboot (required since iOS 16).
5. In Sideloadly: drop the `.ipa`, enter your Apple ID, Start. Sideloadly creates a development certificate and a provisioning profile for this device and signs the app.
6. First launch: Settings → General → VPN & Device Management → trust your developer certificate.

Expected result: the app opens and shows "Cemu iPadOS / Build system online." plus a line with arm64, C++ version, clang version and `hw.machine`.

## Signing requirements (research, Oct 2026)

| Topic | Finding | Confidence |
| --- | --- | --- |
| Free Apple ID | Apps expire after 7 days and must be re-signed; max 3 sideloaded apps active; max 10 new App IDs per 7 days | Documented by Sideloadly and SideStore |
| Paid Developer Program ($99/yr) | No 3-app limit; profiles valid up to 1 year | Documented by Sideloadly |
| Provisioning profile / device registration | Development profiles list device UDIDs. Sideloadly registers the connected iPad automatically for both free and paid accounts | Sideloadly behaviour; confirm on first install |
| Developer Mode | Required on iOS 16+ to run development-signed apps | Documented |
| `get-task-allow` (debugger attach) | Development-signed apps carry it; StikDebug-style JIT relies on attaching a debugger | Mechanism used by all current JIT tools; verify with StikDebug in Phase 5 |
| `increased-memory-limit` | Obtainable with a free Apple ID by enabling the capability on the App ID (tools: GetMoreRam, Xcode). SideStore has had a bug dropping it on free accounts. AltStore 2.2 beta added support | Community-documented, not Apple-documented |
| `extended-virtual-addressing` (needed for Cemu's 4 GB guest reservation) | **Unknown** whether free accounts can get it. Must be tested | Open |
| JIT on iPadOS 27 beta | **Unknown.** iPadOS 26 TXM devices need a debugger to authorise each JIT page; 26.4 reportedly broke offline JIT enabling. Re-check when Phase 5 starts | Open |
| App Store / TestFlight | No JIT: no `get-task-allow`, no `dynamic-codesigning` for third parties | Well established |

### What GitHub Actions can do without storing Apple credentials

- **Can:** compile, link, package an unsigned `.ipa`, run static checks.
- **Cannot:** produce a device-installable (signed) build, register devices, or create provisioning profiles. All of those need an Apple ID session or a certificate + private key.
- **Later option (not now):** a paid account's development certificate (`.p12`) and a provisioning profile stored as encrypted repository secrets would let CI sign. Not recommended for a public repo until there is a reason; signing on the PC with Sideloadly avoids it entirely.

### Can the eventual JIT build be signed with this workflow?

Probably yes, with caveats. Sideloadly/SideStore produce development-signed apps with `get-task-allow`, which is what debugger-based JIT enablers need. Whether this still works on iPadOS 27 and whether `extended-virtual-addressing` survives free-account signing are the two unknowns to test before Phase 5.

## Verification status

- Locally verified (Linux): workflow YAML passes `actionlint` 1.7.7; `project.yml` and `Info.plist` parse.
- **Not verified:** the macOS build itself, the `.ipa`, and device installation. This report must not be read as "build works" until the first GitHub Actions run is green and the app opens on the iPad.

## Sources

- Runner images: [macos-26 arm64 readme](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md), [Xcode 27 preview announcement](https://github.com/actions/runner-images/issues/14404)
- [Sideloadly FAQ](https://sideloadly.io/faq.html), [SideStore FAQ](https://docs.sidestore.io/docs/faq)
- [SideStore issue #1616 (increased-memory-limit dropped)](https://github.com/SideStore/SideStore/issues/1616), [LiveContainer discussion #388](https://github.com/LiveContainer/LiveContainer/discussions/388), [GetMoreRam](https://github.com/pipaandthebaskas/GetMoreRam)
- [iCube: JIT on iOS 26](https://github.com/Provenance-Emu/iCube/issues/11), [PiunikaWeb: iOS 26.4 JIT](https://piunikaweb.com/2026/03/26/ios-26-4-may-break-jit-for-sideloaded-apps/)
