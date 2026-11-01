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

#include "vita3k_bridge.h"

#include "../ios_session.h"
#include "../jit/ios_jit.h"
#include "archive.h"

#include <app/functions.h>
#include <config/functions.h>
#include <config/state.h>
#include <config/version.h>
#include <packages/functions.h>
#include <packages/pkg.h>
#include <util/log.h>
#include <util/string_utils.h>

#include <fmt/format.h>

#include <cctype>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <mutex>
#include <string>

namespace {

// Installs touch the app list and the emulated file system, so only one runs at a time
std::mutex install_mutex;

char *dup_string(const std::string &value) {
    char *out = static_cast<char *>(std::malloc(value.size() + 1));
    if (out)
        std::memcpy(out, value.c_str(), value.size() + 1);
    return out;
}

std::string json_escape(const std::string &value) {
    std::string out;
    out.reserve(value.size() + 2);
    for (const unsigned char c : value) {
        switch (c) {
        case '"': out += "\\\""; break;
        case '\\': out += "\\\\"; break;
        case '\n': out += "\\n"; break;
        case '\r': out += "\\r"; break;
        case '\t': out += "\\t"; break;
        default:
            if (c < 0x20)
                out += fmt::format("\\u{:04x}", c);
            else
                out += static_cast<char>(c);
        }
    }
    return out;
}

std::string quoted(const std::string &value) {
    return "\"" + json_escape(value) + "\"";
}

std::string lower_extension(const fs::path &path) {
    return string_utils::tolower(path.extension().string());
}

int kind_of(const fs::path &path) {
    std::error_code ec;
    if (fs::is_directory(path, ec))
        return 4;
    const auto ext = lower_extension(path);
    if (ext == ".pup")
        return 1;
    if (ext == ".vpk" || ext == ".zip")
        return 2;
    if (ext == ".pkg")
        return 3;
    return 0;
}

std::string read_zrif(const fs::path &pkg_path) {
    fs::path zrif_path = pkg_path;
    zrif_path.replace_extension(".zrif");
    std::ifstream file(zrif_path);
    if (!file)
        return {};
    std::string zrif;
    std::getline(file, zrif);
    std::erase_if(zrif, [](unsigned char c) { return std::isspace(c); });
    return zrif;
}

struct InstallOutcome {
    int installed = 0;
    int failed = 0;
    std::string firmware_version;
};

// Installs one file. Folders are handled by install_path.
bool install_file(EmuEnvState &emuenv, const fs::path &file, const std::string &zrif_in, v3k_progress_fn progress, void *context, InstallOutcome &outcome) {
    const auto report = [&](float percent) {
        if (progress)
            progress(context, percent);
    };

    switch (kind_of(file)) {
    case 1: {
        const auto version = install_pup(emuenv.vita_fs_path, file, [&](uint32_t p) { report(static_cast<float>(p)); });
        if (version.empty())
            return false;
        outcome.firmware_version = version;
        return true;
    }
    case 2: {
        const auto reinstall = [](const std::string &, const std::string &) { return true; };
        const auto progress_fn = [&](ArchiveContents contents) {
            if (contents.progress)
                report(*contents.progress);
            else if (contents.count && contents.current && *contents.count > 0)
                report(*contents.current / *contents.count * 100.f);
        };
        return !install_archive(emuenv, file, progress_fn, reinstall).empty();
    }
    case 3: {
        std::string zrif = zrif_in.empty() ? read_zrif(file) : zrif_in;
        return install_pkg(file, emuenv, zrif, [&](float p) { report(p); });
    }
    default:
        return false;
    }
}

void install_path(EmuEnvState &emuenv, const fs::path &path, const std::string &zrif, v3k_progress_fn progress, void *context, InstallOutcome &outcome) {
    if (kind_of(path) != 4) {
        if (install_file(emuenv, path, zrif, progress, context, outcome))
            outcome.installed++;
        else
            outcome.failed++;
        return;
    }

    // A dumped game folder (sce_sys/param.sfo inside), or several of them
    const uint32_t contents = install_contents(emuenv, path);
    if (contents > 0) {
        outcome.installed += static_cast<int>(contents);
        return;
    }

    // Otherwise a folder of files to install: firmware first, so apps installed next find it
    std::vector<fs::path> files;
    std::error_code ec;
    for (const auto &entry : fs::directory_iterator(path, ec)) {
        if (entry.is_regular_file() && kind_of(entry.path()) != 0)
            files.push_back(entry.path());
    }
    std::ranges::stable_sort(files, [](const fs::path &a, const fs::path &b) {
        return (kind_of(a) == 1) > (kind_of(b) == 1);
    });
    for (const auto &file : files) {
        if (install_file(emuenv, file, {}, progress, context, outcome))
            outcome.installed++;
        else
            outcome.failed++;
    }
}

} // namespace

extern "C" {

const char *v3k_version(void) {
    static const std::string version = fmt::format("{}-{}-{}", app_version, app_number, app_hash);
    return version.c_str();
}

bool v3k_is_jit_enabled(void) {
    return ios::jit_ready();
}

char *v3k_jit_status_text(void) {
    if (ios::jit_preparing())
        return dup_string("Setting up JIT...");
    return dup_string(ios::jit_status().detail);
}

bool v3k_jit_preparing(void) {
    return ios::jit_preparing();
}

bool v3k_jit_can_request(void) {
    return ios::jit_can_request();
}

void v3k_jit_request(void) {
    ios::jit_request_async();
}

const char *v3k_storage_path(void) {
    static const std::string path = ios::get_documents_path();
    return path.c_str();
}

int v3k_firmware_state(void) {
    auto *emuenv = ios::get_emuenv();
    if (!emuenv)
        return 0;
    const auto state = app::get_firmware_state(*emuenv);
    return (state.preinstalled_package ? 1 : 0) | (state.main_firmware ? 2 : 0) | (state.font_package ? 4 : 0);
}

char *v3k_apps_json(void) {
    std::string json = "[";
    bool first = true;
    for (const auto &app : ios::list_apps()) {
        if (!first)
            json += ",";
        first = false;
        json += fmt::format(R"({{"titleId":{},"title":{},"version":{},"category":{},"iconPath":{},"path":{}}})",
            quoted(app.title_id), quoted(app.title), quoted(app.app_ver), quoted(app.category), quoted(app.icon_path), quoted(app.path));
    }
    json += "]";
    return dup_string(json);
}

void v3k_refresh_apps(void) {
    auto *emuenv = ios::get_emuenv();
    if (!emuenv)
        return;
    std::lock_guard lock(install_mutex);
    app::scan_apps(*emuenv);
}

bool v3k_delete_app(const char *title_id) {
    auto *emuenv = ios::get_emuenv();
    if (!emuenv || !title_id)
        return false;
    const auto app = ios::find_app_by_title_id(title_id);
    if (!app)
        return false;
    std::lock_guard lock(install_mutex);
    app::delete_app(*emuenv, app->path);
    app::scan_apps(*emuenv);
    return true;
}

void v3k_free_string(char *str) {
    std::free(str);
}

int v3k_install_kind(const char *path) {
    return path ? kind_of(fs::path(path)) : 0;
}

char *v3k_zrif_next_to(const char *pkg_path) {
    if (!pkg_path)
        return nullptr;
    const auto zrif = read_zrif(fs::path(pkg_path));
    return zrif.empty() ? nullptr : dup_string(zrif);
}

bool v3k_install(const char *path, const char *zrif, v3k_progress_fn progress, void *context, char **message) {
    auto *emuenv = ios::get_emuenv();
    if (!emuenv || !path) {
        if (message)
            *message = dup_string("The emulator is not initialised.");
        return false;
    }

    InstallOutcome outcome;
    {
        std::lock_guard lock(install_mutex);
        try {
            install_path(*emuenv, fs::path(path), zrif ? zrif : "", progress, context, outcome);
        } catch (const std::exception &e) {
            LOG_ERROR("Install of {} threw: {}", path, e.what());
            outcome.failed++;
        }
        if (outcome.installed > 0)
            app::scan_apps(*emuenv);
    }

    if (message) {
        std::string text;
        if (!outcome.firmware_version.empty())
            text = fmt::format("Firmware {} installed.", outcome.firmware_version);
        else if (outcome.installed > 0)
            text = outcome.installed == 1 ? "Installed." : fmt::format("Installed {} items.", outcome.installed);
        if (outcome.failed > 0) {
            if (!text.empty())
                text += " ";
            text += outcome.installed == 0 && outcome.failed == 1
                ? "Installation failed. Check that the file is valid, and that a .pkg has its zRIF license."
                : fmt::format("{} item(s) failed.", outcome.failed);
        }
        if (text.empty())
            text = "Nothing to install was found there.";
        *message = dup_string(text);
    }
    return outcome.failed == 0 && outcome.installed > 0;
}

char *v3k_settings_json(void) {
    auto *emuenv = ios::get_emuenv();
    if (!emuenv)
        return dup_string("{}");
    const auto &cfg = emuenv->cfg;
    const auto b = [](bool v) { return v ? "true" : "false"; };
    const std::string json = fmt::format(
        R"({{"resolutionMultiplier":{},"anisotropicFiltering":{},"audioVolume":{},"screenFilter":{},)"
        R"("vSync":{},"cpuOpt":{},"ngsEnable":{},"highAccuracy":{},"stretchDisplay":{},)"
        R"("performanceOverlay":{},"textureCache":{},"turboMode":{},"pstvMode":{}}})",
        cfg.resolution_multiplier, cfg.anisotropic_filtering, cfg.audio_volume, quoted(cfg.screen_filter),
        b(cfg.v_sync), b(cfg.cpu_opt), b(cfg.ngs_enable), b(cfg.high_accuracy), b(cfg.stretch_the_display_area),
        b(cfg.performance_overlay), b(cfg.texture_cache), b(cfg.turbo_mode), b(cfg.pstv_mode));
    return dup_string(json);
}

namespace {

// Settings are written to both the global config and the active copy, then saved to config.yml
bool save_settings(EmuEnvState &emuenv) {
    return config::serialize_config(emuenv.cfg, emuenv.cfg.config_path) == Success;
}

} // namespace

bool v3k_set_setting_number(const char *key, double value) {
    auto *emuenv = ios::get_emuenv();
    if (!emuenv || !key)
        return false;
    auto &cfg = emuenv->cfg;
    const std::string k = key;
    if (k == "resolution-multiplier") {
        cfg.resolution_multiplier = static_cast<float>(value);
        cfg.current_config.resolution_multiplier = cfg.resolution_multiplier;
    } else if (k == "anisotropic-filtering") {
        cfg.anisotropic_filtering = static_cast<int>(value);
        cfg.current_config.anisotropic_filtering = cfg.anisotropic_filtering;
    } else if (k == "audio-volume") {
        cfg.audio_volume = static_cast<int>(value);
        cfg.current_config.audio_volume = cfg.audio_volume;
    } else {
        return false;
    }
    return save_settings(*emuenv);
}

bool v3k_set_setting_bool(const char *key, bool value) {
    auto *emuenv = ios::get_emuenv();
    if (!emuenv || !key)
        return false;
    auto &cfg = emuenv->cfg;
    const std::string k = key;
    if (k == "v-sync") {
        cfg.v_sync = cfg.current_config.v_sync = value;
    } else if (k == "cpu-opt") {
        cfg.cpu_opt = cfg.current_config.cpu_opt = value;
    } else if (k == "ngs-enable") {
        cfg.ngs_enable = cfg.current_config.ngs_enable = value;
    } else if (k == "high-accuracy") {
        cfg.high_accuracy = cfg.current_config.high_accuracy = value;
    } else if (k == "stretch-display") {
        cfg.stretch_the_display_area = cfg.current_config.stretch_the_display_area = value;
    } else if (k == "texture-cache") {
        cfg.texture_cache = cfg.current_config.texture_cache = value;
    } else if (k == "performance-overlay") {
        cfg.performance_overlay = value;
    } else if (k == "turbo-mode") {
        cfg.turbo_mode = value;
    } else if (k == "pstv-mode") {
        cfg.pstv_mode = value;
    } else {
        return false;
    }
    return save_settings(*emuenv);
}

bool v3k_set_setting_string(const char *key, const char *value) {
    auto *emuenv = ios::get_emuenv();
    if (!emuenv || !key || !value)
        return false;
    auto &cfg = emuenv->cfg;
    if (std::string(key) == "screen-filter") {
        cfg.screen_filter = cfg.current_config.screen_filter = value;
        return save_settings(*emuenv);
    }
    return false;
}

void v3k_request_launch(const char *title_id) {
    if (title_id)
        ios::set_pending_launch(title_id);
}

} // extern "C"
