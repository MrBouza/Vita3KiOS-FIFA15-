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

// Phase 1 bring-up entry point for iOS.
//
// There is no real UI yet. On launch the app:
//   1. initialises the emulator under the app's Documents folder (visible in the Files app),
//   2. installs anything dropped into Documents/Import (.PUP firmware, .vpk/.zip, .pkg + .zrif),
//   3. picks a game: the title ID in Documents/autoboot.txt, or a picker listing installed apps,
//   4. runs it through the shared SDL frontend, the same runner Android uses.
// The SwiftUI frontend replaces steps 2-3 in a later phase.

#include "ios_session.h"

#include <emuenv/app_launch_request.h>
#include <sdl-frontend/session.h>
#include <util/log.h>

#include <SDL3/SDL.h>
#include <SDL3/SDL_main.h>

#include <fmt/format.h>

#include <fstream>
#include <string>
#include <vector>

namespace {

void show_message(const std::string &title, const std::string &message) {
    SDL_ShowSimpleMessageBox(SDL_MESSAGEBOX_INFORMATION, title.c_str(), message.c_str(), nullptr);
}

std::string read_autoboot_title_id(const fs::path &documents) {
    std::ifstream file(documents / "autoboot.txt");
    if (!file)
        return {};
    std::string title_id;
    file >> title_id;
    return title_id;
}

// Lets the user pick one of the installed apps. Returns an empty string when cancelled.
std::string pick_app(const std::vector<app::AppEntry> &apps) {
    // A UIAlertController-backed message box: fine for a handful of apps during bring-up
    constexpr size_t max_buttons = 8;
    const size_t count = std::min(apps.size(), max_buttons);

    std::vector<std::string> labels;
    labels.reserve(count);
    std::vector<SDL_MessageBoxButtonData> buttons;
    buttons.reserve(count + 1);
    for (size_t i = 0; i < count; i++) {
        labels.push_back(fmt::format("{} ({})", apps[i].title, apps[i].title_id));
        buttons.push_back({ 0, static_cast<int>(i), labels.back().c_str() });
    }
    buttons.push_back({ SDL_MESSAGEBOX_BUTTON_ESCAPEKEY_DEFAULT, -1, "Quit" });

    const std::string message = apps.size() > max_buttons
        ? fmt::format("Showing the first {} of {} apps. Put a title ID in Documents/autoboot.txt to launch another one.", max_buttons, apps.size())
        : std::string("Choose an app to launch.");

    const SDL_MessageBoxData data{
        .flags = SDL_MESSAGEBOX_INFORMATION,
        .window = nullptr,
        .title = "Vita3K",
        .message = message.c_str(),
        .numbuttons = static_cast<int>(buttons.size()),
        .buttons = buttons.data(),
        .colorScheme = nullptr,
    };

    int choice = -1;
    if (!SDL_ShowMessageBox(&data, &choice) || choice < 0)
        return {};
    return apps[static_cast<size_t>(choice)].title_id;
}

} // namespace

int main(int argc, char *argv[]) {
    (void)argc;
    (void)argv;

    SDL_SetAppMetadata("Vita3K", nullptr, "org.vita3k.ios");
    if (!SDL_Init(SDL_INIT_VIDEO)) {
        SDL_Log("SDL_Init failed: %s", SDL_GetError());
        return 1;
    }

    const fs::path documents = ios::get_documents_path();
    if (!ios::initialize(documents)) {
        show_message("Vita3K", "The emulator failed to initialise. Check Documents/vita3k.log in the Files app.");
        return 1;
    }

    const auto import = ios::import_pending_files(documents / "Import");
    if (!import.installed.empty() || !import.failed.empty()) {
        std::string summary;
        for (const auto &name : import.installed)
            summary += fmt::format("Installed: {}\n", name);
        for (const auto &name : import.failed)
            summary += fmt::format("Failed: {}\n", name);
        show_message("Import", summary);
    }

    std::string title_id = read_autoboot_title_id(documents);
    if (!title_id.empty() && !ios::find_app_by_title_id(title_id)) {
        show_message("Vita3K", fmt::format("autoboot.txt names {}, which is not installed.", title_id));
        title_id.clear();
    }

    if (title_id.empty()) {
        const auto apps = ios::list_apps();
        if (apps.empty()) {
            show_message("Vita3K",
                "No apps installed yet.\n\nIn the Files app, open On My iPhone > Vita3K and put firmware (.PUP) "
                "and games (.vpk, .zip, or .pkg with a matching .zrif) into the Import folder, then relaunch.");
            return 0;
        }
        title_id = pick_app(apps);
        if (title_id.empty())
            return 0;
    }

    auto *emuenv = ios::get_emuenv();
    auto *session_controller = ios::get_app_session_controller();

    // On-screen keyboard (IME) and touch controls are wired in later phases
    const sdl_frontend::Hooks hooks{};

    LOG_INFO("Launching {}", title_id);
    return sdl_frontend::run(*emuenv, *session_controller, AppLaunchRequest{ .app_path = title_id }, hooks);
}
