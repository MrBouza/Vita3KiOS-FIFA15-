# Vita3KiOS

An experimental PlayStation Vita emulator for iPhone and iPad, built on [Vita3K](https://github.com/Vita3K/Vita3K).

Vita3KiOS runs the full, current Vita3K emulator core (CPU recompiler, GXM→Vulkan renderer via MoltenVK, kernel and module HLE) inside a native iOS app with a SwiftUI library. The iOS JIT support comes from [Tsubomi](https://github.com/125hz/Tsubomi) by 125hz.

> **Status: early.** Games boot and run with JIT on iOS 26 (tested on iPhone 16 Pro through LiveContainer + StikDebug). Game compatibility follows upstream Vita3K: check the [compatibility list](https://vita3k.org/compatibility.html). See [ROADMAP-iOS.md](ROADMAP-iOS.md).

## Features

- Full Vita3K core, kept in sync with upstream
- SwiftUI library with game icons, search, firmware/font/JIT status
- Import firmware (`.PUP`), games as `.vpk`, `.zip`, `.pkg` (with zRIF) or dumped game folders, from the Files picker or the `Import` folder
- iOS 26 JIT through StikDebug's `universal.js` (from Tsubomi), classic debugger JIT on iOS 17.4–18
- Keep your games on an external drive (USB-C SSD, thumb drive, microSD reader) or any folder: **Settings → Storage**
- On-screen touch controls with themes (PlayStation colours, Xbox-style and Nintendo-style A/B/X/Y, Neon, Minimal), adjustable opacity and size, hidden automatically when a controller connects
- Button mapping for controllers, including a one-tap ✕/○ swap
- Eight UI themes, and original menu music composed on the device: endless songs in six styles
- Library sorting by title or recently played, save data management, log sharing from Settings
- Works inside LiveContainer
- Settings for resolution, filtering, V-Sync, CPU options and audio

## Requirements

- iPhone or iPad with an A12 chip or newer, on **iOS 17.4 or later**
- A way to sideload an unsigned `.ipa`: AltStore, SideStore, LiveContainer or TrollStore
- [StikDebug](https://github.com/StephenDev0/StikDebug) for JIT
- Your own PS Vita firmware and game dumps

## Install

1. Download the latest `Vita3K-iOS-<commit>.ipa` from the [iOS workflow](../../actions/workflows/ios.yml) (open the newest successful run, then **Artifacts**).
2. Install it with your sideloading tool. New builds install over old ones and keep your data (bundle ID `org.vita3k.ios`).

## Enabling JIT

Vita3K translates game code at runtime, so it needs JIT. Without it, games won't start, and the app tells you so.

**iOS 26 on an A15/M2 or newer chip (iPhone 13 and later)** needs StikDebug's `universal.js` script:

- **LiveContainer:** long-press Vita3K → Settings → turn on **Launch with JIT** and set **JIT Launch Script** to `universal.js`. In LiveContainer's settings, choose StikDebug as the JIT enabler.
- **Installed directly:** in StikDebug, assign `universal.js` to Vita3K and enable JIT for it.

When Vita3K opens, it prepares its JIT memory while StikDebug is attached (a "Setting up JIT" screen). The status pill turns green (**JIT ready**) when it's done.

**iOS 17.4–18, or older chips:** enabling JIT in StikDebug (or LiveContainer's "Launch with JIT") is enough.

## Adding firmware and games

1. Download the PS Vita firmware (`PSVUPDAT.PUP`) and font package (`PSP2UPDAT.PUP`) from PlayStation's site.
2. In Vita3K, tap **+** → **Files** and pick them. Then add your games the same way, or with **+** → **Game folder** for a dumped folder.
   - `.pkg` files need their zRIF license. Vita3K asks for it, or reads a `.zrif` text file with the same name next to the `.pkg`.
3. Alternatively, copy files into **Files → On My iPhone → Vita3K → Import** and reopen the app.

Data lives in the app's Documents folder (`vita/` holds the Vita file system, `vita3k.log` is the log). Send the log when reporting a problem.

### External storage

**Settings → Storage → Choose folder or drive…** lets you keep games, saves and firmware on an external drive or any other folder the Files app can reach. Vita3K copies your firmware there and remembers the location across launches. If the drive isn't connected when Vita3K starts, it falls back to the device's storage and tells you. If you already have a desktop Vita3K folder (with `ux0` inside), copy it to the drive and pick it directly.

## Building

Builds run on GitHub Actions (`.github/workflows/ios.yml`): CMake generates an Xcode project, `xcodebuild` builds it unsigned, and the app is packaged as an IPA. To build locally on a Mac with Xcode 26 and a bootstrapped [vcpkg](https://github.com/microsoft/vcpkg):

```sh
git clone --recursive https://github.com/oledz-i/Vita3KiOS
cd Vita3KiOS
VCPKG_ROOT=/path/to/vcpkg bash .ci/build-ios.sh artifacts
```

The iOS code lives in `vita3k/ios/` (app target, SwiftUI frontend, C bridge to the core, JIT), with the dynarmic JIT patch in `vita3k/ios/patches/` (applied automatically at configure time).

## Credits

- **[Vita3K](https://github.com/Vita3K/Vita3K)** and its contributors: the emulator this app is built on. Please support the upstream project.
- **[Tsubomi](https://github.com/125hz/Tsubomi)** by **125hz**: the iOS 26 JIT implementation (`vita3k/ios/patches/0001-oaknut-ios-rwx-jit.patch` and the JIT region pool), guest memory pre-reservation, the iOS audio session setup and the high-density game window.
- **[dynarmic](https://github.com/merryhime/dynarmic)** and **oaknut** by merryhime, **[MoltenVK](https://github.com/KhronosGroup/MoltenVK)**, **[SDL](https://github.com/libsdl-org/SDL)**, and the other libraries in `external/`.

## Legal

Vita3KiOS doesn't include any games, firmware or keys. Only use content you dumped from hardware you own. This project isn't affiliated with Sony.

Licensed under the GNU General Public License v2 or later, like Vita3K. See [COPYING.txt](COPYING.txt).
