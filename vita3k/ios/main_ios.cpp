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

// iOS entry point. SDL owns the UIApplication; this function runs once UIKit has launched.
//
//   1. Initialise the emulator under the app's Documents folder (visible in the Files app, and
//      redirected to the container when running inside LiveContainer).
//   2. Install anything dropped into Documents/Import.
//   3. Loop: show the SwiftUI library until a game is picked, then run it through the shared
//      SDL frontend (the same runner Android uses). When the game exits, the library comes back.

#include "ios_session.h"

#include <emuenv/app_launch_request.h>
#include <sdl-frontend/session.h>
#include <util/log.h>

#include <SDL3/SDL.h>
#include <SDL3/SDL_main.h>

#include <string>

namespace {

void show_message(const std::string &title, const std::string &message) {
    SDL_ShowSimpleMessageBox(SDL_MESSAGEBOX_INFORMATION, title.c_str(), message.c_str(), nullptr);
}

} // namespace

int main(int argc, char *argv[]) {
    (void)argc;
    (void)argv;

    SDL_SetAppMetadata("Vita3K", nullptr, "org.vita3k.ios");

    const fs::path documents = fs::path(ios::get_documents_path());
    if (!ios::initialize(documents)) {
        show_message("Vita3K", "The emulator failed to initialise. Check vita3k.log in the app's folder in the Files app.");
        return 1;
    }

    // Files dropped into Documents/Import through the Files app or a computer
    const auto import = ios::import_pending_files(documents / "Import");
    LOG_INFO("Startup import: {} installed, {} failed", import.installed.size(), import.failed.size());

    auto *emuenv = ios::get_emuenv();
    auto *session_controller = ios::get_app_session_controller();

    for (;;) {
        const std::string title_id = ios::run_library_until_launch();
        if (!ios::find_app_by_title_id(title_id)) {
            LOG_ERROR("Requested app {} is not installed", title_id);
            continue;
        }

        LOG_INFO("Launching {} (JIT {})", title_id, ios::is_jit_enabled() ? "enabled" : "NOT enabled");

        // The library can rotate freely; games are landscape only
        SDL_SetHint(SDL_HINT_ORIENTATIONS, "LandscapeLeft LandscapeRight");

        // On-screen keyboard (IME) and touch controls are wired in later
        const sdl_frontend::Hooks hooks{};
        const int result = sdl_frontend::run(*emuenv, *session_controller, AppLaunchRequest{ .app_path = title_id }, hooks);
        LOG_INFO("{} exited with code {}", title_id, result);
    }
}
