// Vita3K emulator project
// Copyright (C) 2026 Vita3K team
//
// This program is free software; you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 2 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License along
// with this program; if not, write to the Free Software Foundation, Inc.,
// 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

#pragma once

// Platform queries implemented in Objective-C++ (ios_platform.mm).
// Keep this header free of Vita3K includes: Apple's headers define names such as Ptr
// that clash with Vita3K's own, so the .mm side must never see both.

#include <string>

namespace ios {

std::string get_documents_path();
std::string get_bundle_resources_path();
std::string get_os_version();
std::string get_device_model();

// True when a debugger has attached to the process (CS_DEBUGGED), which is how StikDebug
// enables JIT for sideloaded apps. dynarmic cannot run guest code without it.
bool is_jit_enabled();

// Library UI (SwiftUI, see ui/). Shows it and runs the main run loop until the user picks a game,
// then hides it and returns that game's title ID.
std::string run_library_until_launch();

// Custom storage location (a folder on the device or an external drive), chosen in Settings and
// remembered as a security-scoped bookmark. Returns the folder's path with access started, or an
// empty string when none is set or it can't be reached (note then says why, e.g. drive unplugged).
std::string resolve_custom_storage(std::string &note);

// Keeps the screen from dimming and locking while a game runs
void set_screen_always_on(bool on);
// Tracks whether the app is in the background (call observe_app_state once at startup)
void observe_app_state();
bool app_in_background();

// Sets the AVAudioSession to Playback at 48 kHz and activates it. Returns a line for the log.
std::string configure_audio_session();
void set_pending_launch(const std::string &title_id);

// HTTPS GET through NSURLSession (system certificates and proxies; the bundled OpenSSL has no CA list
// on iOS, so curl can't verify servers). Blocking: call off the main thread. Follows redirects.
bool download(const std::string &url, std::string &data, std::string &error);

} // namespace ios
