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

#include "bridge/vita3k_bridge.h"
#include "controls/virtual_pad.h"
#include "ios_session.h"
#include "jit/ios_jit.h"

#include <app/session_controller.h>
#include <emuenv/app_launch_request.h>
#include <mem/functions.h>
#include <sdl-frontend/session.h>
#include <util/log.h>

#include <SDL3/SDL.h>
#include <SDL3/SDL_main.h>
#include <os/proc.h>

#include <atomic>
#include <chrono>
#include <string>
#include <thread>

#include <spdlog/spdlog.h>
#include <unistd.h>

// Implemented in Swift (ui/TouchControls.swift)
extern "C" void v3k_controls_attach(void *ui_window);
extern "C" void v3k_controls_detach(void);

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

    ios::install_fatal_signal_logger();
    ios::observe_app_state();

    // Activate the audio session before SDL opens the audio device, so the audio unit actually runs
    // (otherwise games that wait on audio playback freeze). From Tsubomi.
    LOG_INFO("{}", ios::configure_audio_session());

    // Prepare the JIT region pool now, while StikDebug is still attached: it usually detaches within
    // a minute of launch, and new executable regions can't be prepared after that (iOS 26).
    // Same order as Tsubomi: guest memory is reserved first, inside prepare_jit_pool().
    const bool jit_capable = ios::jit_capability_enabled();
    LOG_INFO("JIT probe: capability {}, debugger attached {}", jit_capable ? "yes" : "no", ios::debugger_attached() ? "yes" : "no");
    // The library starts JIT preparation right after its first frame (LibraryHost.swift), so the app
    // appears immediately; StikDebug briefly pauses the app for each region it prepares.
    (void)jit_capable;

    // Files dropped into Documents/Import through the Files app or a computer
    const auto import = ios::import_pending_files(documents / "Import");
    LOG_INFO("Startup import: {} installed, {} failed", import.installed.size(), import.failed.size());

    auto *emuenv = ios::get_emuenv();

    for (;;) {
        const std::string title_id = ios::run_library_until_launch();
        if (!ios::find_app_by_title_id(title_id)) {
            LOG_ERROR("Requested app {} is not installed", title_id);
            continue;
        }

        // Re-reserve guest memory before every launch, so a second session gets the same clean
        // address range as the first instead of whatever the previous session left fragmented
        prereserve_guest_memory();

        LOG_INFO("Launching {} (JIT {}, {} free JIT caches, {} MiB of memory available)", title_id,
            ios::jit_pool_ready() ? "ready" : "NOT ready", ios::jit_pool_available(),
            os_proc_available_memory() / (1024 * 1024));

        // The library can rotate freely; games are landscape only
        SDL_SetHint(SDL_HINT_ORIENTATIONS, "LandscapeLeft LandscapeRight");

        // A fresh session controller per launch (as Tsubomi does): no state carried over from the last game
        app::AppSessionController session_controller(*emuenv);

        // Watchdog: logs memory headroom and stalls, and makes sure Quit always gets you out even if the
        // game is stuck (iOS has no other way to leave a hung game except the app switcher)
        std::atomic_bool session_over{ false };
        std::thread watchdog([emuenv, &session_over] {
            using namespace std::chrono_literals;
            size_t last_frames = emuenv->frame_count;
            auto last_progress = std::chrono::steady_clock::now();
            auto last_memory_log = last_progress;
            bool stall_logged = false;
            while (!session_over.load()) {
                std::this_thread::sleep_for(500ms);
                const auto now = std::chrono::steady_clock::now();
                if (emuenv->frame_count != last_frames) {
                    last_frames = emuenv->frame_count;
                    last_progress = now;
                    if (stall_logged)
                        LOG_INFO("Watchdog: the game is presenting frames again");
                    stall_logged = false;
                } else if (!stall_logged && now - last_progress > 8s && !ios::app_in_background()) {
                    LOG_WARN("Watchdog: no new frame for 8 seconds (the game may be frozen). {} MiB of memory left",
                        os_proc_available_memory() / (1024 * 1024));
                    stall_logged = true;
                }
                if (now - last_memory_log > 10s) {
                    LOG_INFO("Watchdog: {} MiB of memory left, {} frames", os_proc_available_memory() / (1024 * 1024), last_frames);
                    last_memory_log = now;
                }
                const uint64_t quit_at = v3k_pad_quit_requested_ms();
                if (quit_at && SDL_GetTicks() - quit_at > 8000) {
                    LOG_CRITICAL("Watchdog: the game did not close 8 seconds after Quit, closing Vita3K");
                    if (auto logger = spdlog::default_logger())
                        logger->flush();
                    _exit(0);
                }
            }
        });

        // On-screen touch controls: a virtual gamepad plus an overlay on the game window
        const sdl_frontend::Hooks hooks{
            .on_window = [](SDL_Window *window) {
                if (window) {
                    if (!v3k_pad_attach())
                        LOG_WARN("Touch controls unavailable: {}", SDL_GetError());
                    void *ui_window = SDL_GetPointerProperty(SDL_GetWindowProperties(window), SDL_PROP_WINDOW_UIKIT_WINDOW_POINTER, nullptr);
                    v3k_controls_attach(ui_window);
                    ios::set_screen_always_on(true);
                } else {
                    ios::set_screen_always_on(false);
                    v3k_controls_detach();
                    v3k_pad_detach();
                }
            },
        };
        const int result = sdl_frontend::run(*emuenv, session_controller, AppLaunchRequest{ .app_path = title_id }, hooks);
        session_over = true;
        watchdog.join();
        v3k_pad_clear_quit_request();
        LOG_INFO("{} exited with code {}, {} free JIT caches", title_id, result, ios::jit_pool_available());
    }
}
