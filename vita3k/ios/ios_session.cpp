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

#include "ios_session.h"
#include "archive.h"

#include <compat/functions.h>
#include <compat/state.h>
#include <config/functions.h>
#include <config/settings.h>
#include <config/version.h>
#include <modules/module_parent.h>
#include <packages/functions.h>
#include <packages/pkg.h>
#include <renderer/functions.h>
#include <util/log.h>
#include <util/string_utils.h>
#include <util/sysinfo.h>

#include <SDL3/SDL.h>

#include <algorithm>
#include <cctype>
#include <fstream>

namespace ios {

SessionState &session_state() {
    static SessionState state;
    return state;
}

EmuEnvState *get_emuenv() {
    return session_state().emuenv.get();
}

app::AppSessionController *get_app_session_controller() {
    return session_state().app_session_controller.get();
}

bool initialize(const fs::path &storage_path) {
    auto &session = session_state();
    if (session.emuenv)
        return true;

    try {
        Root root_paths;
        // The bundle holds data/ and shaders-builtin/ at its root
        root_paths.set_static_assets_path(fs::path(get_bundle_resources_path()));
        root_paths.set_vita_fs_path(storage_path / "vita");
        root_paths.set_log_path(storage_path);
        root_paths.set_config_path(storage_path);
        root_paths.set_shared_path(storage_path);
        root_paths.set_cache_path(storage_path / "cache");
        root_paths.set_patch_path(storage_path / "patch");

        fs::create_directories(root_paths.get_vita_fs_path());
        fs::create_directories(root_paths.get_config_path());
        fs::create_directories(root_paths.get_cache_path());
        fs::create_directories(root_paths.get_log_path() / "shaderlog");
        fs::create_directories(root_paths.get_log_path() / "texturelog");
        fs::create_directories(root_paths.get_patch_path());
        fs::create_directories(root_paths.get_shared_path() / "textures");

        if (logging::init(root_paths, true) != Success)
            return false;

        LOG_INFO("{}", window_title);
        LOG_INFO("OS: {}", get_os_version());
        LOG_INFO("Device: {}", get_device_model());
        LOG_INFO("CPU: {}", util::get_system_info());
        LOG_INFO("Available ram memory: {} MiB", SDL_GetSystemRAM());

        auto emuenv = std::make_unique<EmuEnvState>();

        Config cfg{};
        char arg0[] = "vita3k";
        char *argv[] = { arg0, nullptr };
        if (config::init_config(cfg, 1, argv, root_paths, false) != Success) {
            LOG_ERROR("Failed to initialise config.");
            return false;
        }

        fs::create_directories(cfg.get_vita_fs_path());

        // Trace logging (the desktop default) writes every file access and costs a lot of speed on a
        // phone: use info unless a quieter level was chosen
        if (cfg.log_level < static_cast<int>(spdlog::level::info)) {
            cfg.log_level = static_cast<int>(spdlog::level::info);
            logging::set_level(spdlog::level::info);
            LOG_INFO("log-level: info (iOS default)");
        }

        if (!app::init(*emuenv, cfg, root_paths)) {
            LOG_ERROR("Failed to initialise emulated environment.");
            return false;
        }

        emuenv->vulkan_device_info = std::make_unique<renderer::VulkanDeviceInfo>(renderer::enumerate_vulkan_devices());

        init_libraries(*emuenv);

        if (!app::init_apps_list(*emuenv))
            LOG_ERROR("Failed to initialise apps list.");

        app::load_users(*emuenv);
        if (!app::ensure_current_user(*emuenv)) {
            LOG_ERROR("Failed to initialize active user.");
            return false;
        }
        compat::load_from_disk(emuenv->compat, std::filesystem::path(emuenv->cache_path.string()));

        session.root_paths = std::move(root_paths);
        session.emuenv = std::move(emuenv);
        session.app_session_controller = std::make_unique<app::AppSessionController>(*session.emuenv);
        LOG_INFO("Vita3K iOS initialised.");
        return true;
    } catch (const std::exception &error) {
        LOG_ERROR("Failed to initialize iOS storage path '{}': {}", storage_path, error.what());
        return false;
    }
}

std::vector<app::AppEntry> list_apps() {
    auto *emuenv = get_emuenv();
    if (!emuenv)
        return {};
    return app::get_apps(*emuenv);
}

std::optional<app::AppEntry> find_app_by_title_id(const std::string &title_id) {
    const auto apps = list_apps();
    const auto it = std::ranges::find_if(apps, [&](const app::AppEntry &app) { return app.title_id == title_id; });
    if (it == apps.end())
        return std::nullopt;
    return *it;
}

namespace {

std::string lower_extension(const fs::path &path) {
    return string_utils::tolower(path.extension().string());
}

// A package's zRIF license is read from a text file next to it with the same name: GAME.pkg + GAME.zrif
std::string read_zrif_for(const fs::path &pkg_path) {
    fs::path zrif_path = pkg_path;
    zrif_path.replace_extension(".zrif");
    std::ifstream file(zrif_path);
    if (!file)
        return {};
    std::string zrif;
    std::getline(file, zrif);
    zrif.erase(std::remove_if(zrif.begin(), zrif.end(), [](unsigned char c) { return std::isspace(c); }), zrif.end());
    return zrif;
}

void move_into(const fs::path &file, const fs::path &dir) {
    std::error_code ec;
    fs::create_directories(dir, ec);
    fs::rename(file, dir / file.filename(), ec);
    if (ec)
        LOG_WARN("Could not move {} into {}: {}", file, dir, ec.message());
}

} // namespace

ImportResult import_pending_files(const fs::path &import_dir) {
    ImportResult result;
    auto *emuenv = get_emuenv();
    if (!emuenv)
        return result;

    std::error_code ec;
    fs::create_directories(import_dir, ec);

    std::vector<fs::path> files;
    for (const auto &entry : fs::directory_iterator(import_dir, ec)) {
        if (entry.is_regular_file())
            files.push_back(entry.path());
    }
    // Firmware first, so that apps installed in the same pass find it
    std::ranges::stable_sort(files, [](const fs::path &a, const fs::path &b) {
        return (lower_extension(a) == ".pup") > (lower_extension(b) == ".pup");
    });

    bool installed_any = false;
    for (const auto &file : files) {
        const auto ext = lower_extension(file);
        const auto name = file.filename().string();
        bool handled = true;
        bool ok = false;

        if (ext == ".pup") {
            LOG_INFO("Installing firmware {}", name);
            ok = !install_pup(emuenv->vita_fs_path, file).empty();
        } else if (ext == ".vpk" || ext == ".zip") {
            LOG_INFO("Installing archive {}", name);
            const auto reinstall = [](const std::string &, const std::string &) { return true; };
            ok = !install_archive(*emuenv, file, nullptr, reinstall).empty();
        } else if (ext == ".pkg") {
            LOG_INFO("Installing package {}", name);
            std::string zrif = read_zrif_for(file);
            ok = install_pkg(file, *emuenv, zrif);
        } else {
            handled = false; // .zrif files and anything unknown stay where they are
        }

        if (!handled)
            continue;

        if (ok) {
            installed_any = true;
            result.installed.push_back(name);
            move_into(file, import_dir / "done");
        } else {
            LOG_ERROR("Failed to install {}", name);
            result.failed.push_back(name);
            move_into(file, import_dir / "failed");
        }
    }

    if (installed_any)
        app::scan_apps(*emuenv);

    return result;
}

} // namespace ios
