# Vita3KiOS roadmap

Vita3KiOS is upstream [Vita3K](https://github.com/Vita3K/Vita3K) with an iOS layer added on top.

## Ground rules (why this attempt is different)

1. **Stay a fork, not a copy.** `main` carries upstream history. Upstream is merged in regularly (`git fetch upstream && git merge upstream/master`), so we get their fixes for free.
2. **Keep the diff small and in one place.** iOS code lives in `vita3k/ios/`, `.ci/build-ios.sh` and `.github/workflows/ios.yml`. Changes to shared files are small `if(IOS)` / `TARGET_OS_IPHONE` guards, never rewrites. That keeps upstream merges painless and makes the changes upstreamable later.
3. **Mirror Android, not desktop.** Upstream's Android port already splits things the right way: a native UI (Kotlin), a thin C++ bridge (`vita3k/android/jni/`), and the shared SDL runner (`sdl_frontend::run`). iOS does the same with SwiftUI, an Objective-C++ bridge, and the same runner. The desktop Qt GUI isn't built on iOS.
4. **CI is the build machine.** Every push builds an IPA on GitHub Actions. No Mac needed.
5. **Small, testable steps.** Each phase ends with something you can install and check.

## Platform choices

| Area | Choice |
|---|---|
| Minimum iOS | 17.4 (oldest iOS StikDebug supports) |
| Graphics | Vulkan via MoltenVK, statically linked (`moltenvk_static`) |
| Windowing/input/audio | SDL3 (static), cubeb |
| Third-party libs | vcpkg `arm64-ios` (OpenSSL, curl, zlib, boost) |
| ffmpeg | Vita3K's `ffmpeg-core` prebuilts (they already ship `ffmpeg-ios`) |
| JIT | dynarmic arm64 backend. JIT is enabled with StikDebug (needs `get-task-allow`) |
| Install | Unsigned IPA from CI → AltStore / SideStore |

## Phases

### Phase 1 — It builds and launches *(in progress)*
- [x] Upstream history imported
- [x] CMake: `IOS` detection, Qt GUI off, static SDL, MoltenVK for iOS, vcpkg OpenSSL
- [x] `vita3k/ios/`: app target, Info.plist, entitlements, session bootstrap (counterpart of Android's `native_bootstrap.cpp`)
- [x] Bring-up launcher: installs files from `Documents/Import`, picks a game with `Documents/autoboot.txt` or a simple picker
- [x] GitHub Actions workflow → `Vita3K-iOS-<sha>.ipa` artifact
- [ ] Fix compile and link errors until CI is green
- [ ] App launches on a device and writes `Documents/vita3k.log`

### Phase 2 — JIT on device
- dynarmic's code buffer (`oaknut::CodeBlock`) on iOS currently switches between RW and RX with `mprotect`. That only works once a debugger is attached, and it breaks on iOS 26 TXM devices.
- Add one iOS JIT memory module (`vita3k/ios/jit_memory`) with two modes:
  - **Legacy (iOS 17.4–18.x):** dual-map the code buffer (an RW view plus an RX view via `vm_remap`) after StikDebug attaches.
  - **iOS 26 / TXM:** support StikDebug's `universal.js` script protocol.
- Detect JIT at startup (`CS_DEBUGGED`). If it's missing, show a clear "Enable JIT in StikDebug" screen instead of crashing.
- Make `oaknut::CodeBlock` use it with a small patch to the dynarmic submodule (kept as a patch file we can re-apply).

### Phase 3 — Renders a game
- Vulkan surface from SDL's UIKit Metal view. Check MoltenVK feature gaps against what the renderer needs.
- Shader cache stored under `Documents/cache`.
- Test against a homebrew title first, then a light commercial game.

### Phase 4 — Real frontend (SwiftUI)
- Objective-C++ bridge `vita3k/ios/bridge/` that mirrors Android's `native_*.cpp` API: apps, install, config, users, trophies, session.
- SwiftUI app: library grid, file importer (firmware/pkg/vpk), settings, pause menu. SDL view controller for the game.
- Touch controls overlay (port Android's `input_overlay`), MFi/DualSense controllers, the iOS keyboard for the IME.

### Phase 5 — Polish
- Background/foreground pause, audio session handling, ProMotion frame pacing, thermal notes.
- AltStore/SideStore source JSON for one-tap updates.
- Upstream the generic `if(IOS)` pieces back to Vita3K.

## Developer notes

- **Test builds:** Actions tab → iOS workflow → download the `Vita3K-iOS-<sha>` artifact.
- **Getting files onto the device:** Files app → On My iPhone → Vita3K → `Import/`. Put a `.zrif` text file next to a `.pkg` with the same name.
- **Logs:** `Documents/vita3k.log`.
- **Syncing upstream:** `git remote add upstream https://github.com/Vita3K/Vita3K && git fetch upstream && git merge upstream/master`
