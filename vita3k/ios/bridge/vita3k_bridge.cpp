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

#include "../crash_report.h"
#include "../ios_platform.h"
#include "../ios_session.h"
#include "../jit/ios_jit.h"
#include "archive.h"

#include <app/functions.h>
#include <config/functions.h>
#include <config/settings.h>
#include <config/state.h>
#include <config/version.h>
#include <io/state.h>
#include <miniz.h>
#include <packages/functions.h>
#include <packages/pkg.h>
#include <patch/patch.h>
#include <util/log.h>
#include <util/net_utils.h>
#include <util/string_utils.h>

#include <fmt/format.h>

#include <algorithm>
#include <atomic>
#include <cctype>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <fstream>
#include <map>
#include <mutex>
#include <optional>
#include <string>
#include <thread>

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

namespace {
std::atomic_bool jit_preparing{ false };
}

bool v3k_is_jit_enabled(void) {
    return ios::jit_pool_ready();
}

char *v3k_jit_status_text(void) {
    if (jit_preparing)
        return dup_string(fmt::format("Preparing JIT ({}/{})...", ios::jit_pool_progress(), ios::jit_pool_target()));
    return dup_string(ios::jit_status_text());
}

bool v3k_jit_preparing(void) {
    return jit_preparing;
}

int v3k_jit_progress(void) {
    return ios::jit_pool_progress();
}

int v3k_jit_target(void) {
    return ios::jit_pool_target();
}

bool v3k_jit_can_request(void) {
    return ios::jit_can_prepare();
}

void v3k_jit_request(void) {
    if (jit_preparing.exchange(true))
        return;
    std::thread([] {
        if (ios::prepare_jit_pool())
            LOG_INFO("JIT region pool prepared");
        else
            LOG_WARN("JIT region pool preparation failed: {}", ios::jit_status_text());
        jit_preparing = false;
    }).detach();
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
    auto *emuenv = ios::get_emuenv();
    const auto times = emuenv ? app::get_user_app_times(*emuenv) : std::map<std::string, app::AppTime>{};
    for (const auto &app : ios::list_apps()) {
        if (!first)
            json += ",";
        first = false;
        const auto time = times.find(app.path);
        const long long last_played = time != times.end() ? static_cast<long long>(time->second.last_time_used) : 0;
        const long long play_time = time != times.end() ? static_cast<long long>(time->second.time_used) : 0;
        const bool custom = emuenv && config::has_custom_config(emuenv->config_path, app.path);
        json += fmt::format(R"({{"titleId":{},"title":{},"version":{},"category":{},"iconPath":{},"path":{},"lastPlayed":{},"playTime":{},"customConfig":{}}})",
            quoted(app.title_id), quoted(app.title), quoted(app.app_ver), quoted(app.category), quoted(app.icon_path), quoted(app.path), last_played,
            play_time, custom ? "true" : "false");
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

bool v3k_delete_save_data(const char *title_id) {
    auto *emuenv = ios::get_emuenv();
    if (!emuenv || !title_id)
        return false;
    const auto app = ios::find_app_by_title_id(title_id);
    if (!app || app->savedata.empty())
        return false;
    const fs::path savedata = emuenv->vita_fs_path / "ux0/user" / emuenv->io.user_id / "savedata" / app->savedata;
    std::error_code ec;
    fs::remove_all(savedata, ec);
    LOG_INFO("Deleted save data of {}: {}", title_id, ec ? ec.message() : "ok");
    return !ec;
}

char *v3k_storage_info_json(void) {
    auto *emuenv = ios::get_emuenv();
    if (!emuenv)
        return dup_string("{}");
    std::error_code ec;
    const auto space = fs::space(emuenv->vita_fs_path, ec);
    return dup_string(fmt::format(R"({{"path":{},"custom":{},"freeBytes":{},"totalBytes":{},"note":{}}})",
        quoted(emuenv->vita_fs_path.string()), ios::using_custom_storage() ? "true" : "false",
        ec ? 0 : space.available, ec ? 0 : space.capacity, quoted(ios::storage_note())));
}

bool v3k_set_storage_folder(const char *folder, char **message) {
    std::string text;
    bool ok = false;
    if (folder) {
        std::lock_guard lock(install_mutex);
        ok = ios::switch_storage(ios::vita_root_for(fs::path(folder)), true, text);
    }
    if (message)
        *message = dup_string(text);
    return ok;
}

bool v3k_use_internal_storage(char **message) {
    std::string text;
    bool ok;
    {
        std::lock_guard lock(install_mutex);
        ok = ios::switch_storage(ios::internal_vita_root(), false, text);
    }
    if (message)
        *message = dup_string(text);
    return ok;
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
        R"("performanceOverlay":{},"textureCache":{},"turboMode":{},"pstvMode":{},"memoryMapping":{}}})",
        cfg.resolution_multiplier, cfg.anisotropic_filtering, cfg.audio_volume, quoted(cfg.screen_filter),
        b(cfg.v_sync), b(cfg.cpu_opt), b(cfg.ngs_enable), b(cfg.high_accuracy), b(cfg.stretch_the_display_area),
        b(cfg.performance_overlay), b(cfg.texture_cache), b(cfg.turbo_mode), b(cfg.pstv_mode),
        b(cfg.memory_mapping != "disabled"));
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
    } else if (k == "memory-mapping") {
        cfg.memory_mapping = cfg.current_config.memory_mapping = value ? "double-buffer" : "disabled";
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

namespace {
void ensure_binds(EmuEnvState &emuenv) {
    if (emuenv.cfg.controller_binds.size() < 15 || emuenv.cfg.controller_axis_binds.size() < 6)
        app::reset_controller_binding(emuenv);
}
} // namespace

char *v3k_controller_binds_json(void) {
    auto *emuenv = ios::get_emuenv();
    if (!emuenv)
        return dup_string("[]");
    ensure_binds(*emuenv);
    std::string json = "[";
    for (size_t i = 0; i < 15; i++)
        json += (i ? "," : "") + std::to_string(emuenv->cfg.controller_binds[i]);
    return dup_string(json + "]");
}

bool v3k_set_controller_bind(int slot, int physical_button) {
    auto *emuenv = ios::get_emuenv();
    if (!emuenv || slot < 0 || slot >= 15 || physical_button < 0 || physical_button >= 15)
        return false;
    ensure_binds(*emuenv);
    emuenv->cfg.controller_binds[slot] = static_cast<short>(physical_button);
    return save_settings(*emuenv);
}

void v3k_reset_controller_binds(void) {
    auto *emuenv = ios::get_emuenv();
    if (!emuenv)
        return;
    app::reset_controller_binding(*emuenv);
    save_settings(*emuenv);
}

const char *v3k_log_path(void) {
    static const std::string path = (fs::path(ios::get_documents_path()) / "vita3k.log").string();
    return path.c_str();
}

void v3k_request_launch(const char *title_id) {
    if (title_id)
        ios::set_pending_launch(title_id);
}

} // extern "C"

// ======================================================================================
// Crash reports, shader cache, per-game settings, save backups, game patches
// ======================================================================================

namespace {

std::optional<app::AppEntry> app_for(const char *title_id) {
    if (!title_id)
        return std::nullopt;
    return ios::find_app_by_title_id(title_id);
}

uint64_t folder_size(const fs::path &folder) {
    std::error_code ec;
    uint64_t total = 0;
    if (!fs::exists(folder, ec))
        return 0;
    for (auto it = fs::recursive_directory_iterator(folder, ec); !ec && it != fs::recursive_directory_iterator(); it.increment(ec)) {
        if (it->is_regular_file(ec))
            total += it->file_size(ec);
    }
    return total;
}

fs::path save_folder(EmuEnvState &emuenv, const app::AppEntry &app) {
    return emuenv.vita_fs_path / "ux0/user" / emuenv.io.user_id / "savedata" / app.savedata;
}

std::string timestamp() {
    const std::time_t now = std::time(nullptr);
    char buffer[32];
    std::strftime(buffer, sizeof(buffer), "%Y-%m-%d-%H%M%S", std::localtime(&now));
    return buffer;
}

std::string safe_file_name(const std::string &name) {
    std::string out;
    for (const char c : name)
        out += (std::isalnum(static_cast<unsigned char>(c)) || c == '-' || c == '_' || c == ' ') ? c : '_';
    return out.empty() ? std::string("game") : out;
}

} // namespace

char *v3k_take_crash_report(void) {
    const std::string report = ios::crash::take_previous_report();
    if (report.empty())
        return nullptr;
    return dup_string(fmt::format(R"({{"report":{},"log":{}}})", quoted(report), quoted(ios::crash::previous_log_path())));
}

// ---- Shader cache ----

double v3k_shader_cache_bytes(const char *title_id) {
    auto *emuenv = ios::get_emuenv();
    if (!emuenv || !title_id)
        return 0;
    return static_cast<double>(folder_size(emuenv->cache_path / "shaders" / title_id));
}

bool v3k_delete_shader_cache(const char *title_id) {
    auto *emuenv = ios::get_emuenv();
    if (!emuenv || !title_id)
        return false;
    std::error_code ec;
    fs::remove_all(emuenv->cache_path / "shaders" / title_id, ec);
    LOG_INFO("Deleted the shader cache of {}: {}", title_id, ec ? ec.message() : "ok");
    return !ec;
}

// ---- Per-game settings ----

char *v3k_game_settings_json(const char *title_id) {
    auto *emuenv = ios::get_emuenv();
    const auto app = app_for(title_id);
    if (!emuenv || !app)
        return dup_string("{}");
    Config copy = emuenv->cfg;
    config::set_current_config(copy, emuenv->config_path, app->path);
    const Config::CurrentConfig &cc = copy.current_config;
    const bool custom = config::has_custom_config(emuenv->config_path, app->path);
    const auto b = [](bool v) { return v ? "true" : "false"; };
    return dup_string(fmt::format(
        R"({{"custom":{},"resolutionMultiplier":{},"anisotropicFiltering":{},"screenFilter":{},"memoryMapping":{},)"
        R"("highAccuracy":{},"textureCache":{},"cpuOpt":{},"vSync":{},"fpsHack":{},"disableSurfaceSync":{},)"
        R"("stretchDisplay":{},"asyncShaders":{},"shaderCache":{}}})",
        b(custom), cc.resolution_multiplier, cc.anisotropic_filtering, quoted(cc.screen_filter), b(cc.memory_mapping != "disabled"),
        b(cc.high_accuracy), b(cc.texture_cache), b(cc.cpu_opt), b(cc.v_sync), b(cc.fps_hack), b(cc.disable_surface_sync),
        b(cc.stretch_the_display_area), b(cc.async_pipeline_compilation), b(cc.shader_cache)));
}

bool v3k_set_game_setting(const char *title_id, const char *key, const char *value) {
    auto *emuenv = ios::get_emuenv();
    const auto app = app_for(title_id);
    if (!emuenv || !app || !key || !value)
        return false;
    Config copy = emuenv->cfg;
    config::set_current_config(copy, emuenv->config_path, app->path);
    Config::CurrentConfig &cc = copy.current_config;

    const std::string k = key;
    const std::string v = value;
    const bool on = v == "true" || v == "1";
    if (k == "resolution-multiplier")
        cc.resolution_multiplier = std::stof(v);
    else if (k == "anisotropic-filtering")
        cc.anisotropic_filtering = std::stoi(v);
    else if (k == "screen-filter")
        cc.screen_filter = v;
    else if (k == "memory-mapping")
        cc.memory_mapping = on ? "double-buffer" : "disabled";
    else if (k == "high-accuracy")
        cc.high_accuracy = on;
    else if (k == "texture-cache")
        cc.texture_cache = on;
    else if (k == "cpu-opt")
        cc.cpu_opt = on;
    else if (k == "v-sync")
        cc.v_sync = on;
    else if (k == "fps-hack")
        cc.fps_hack = on;
    else if (k == "disable-surface-sync")
        cc.disable_surface_sync = on;
    else if (k == "stretch-display")
        cc.stretch_the_display_area = on;
    else if (k == "async-shaders")
        cc.async_pipeline_compilation = on;
    else if (k == "shader-cache")
        cc.shader_cache = on;
    else
        return false;
    return config::save_custom_config(cc, emuenv->config_path, app->path);
}

bool v3k_reset_game_settings(const char *title_id) {
    auto *emuenv = ios::get_emuenv();
    const auto app = app_for(title_id);
    if (!emuenv || !app)
        return false;
    return config::delete_custom_config(emuenv->config_path, app->path);
}

// ---- Save data backups ----

char *v3k_export_save_data(const char *title_id, char **message) {
    auto *emuenv = ios::get_emuenv();
    const auto app = app_for(title_id);
    const auto fail = [&](const std::string &text) -> char * {
        if (message)
            *message = dup_string(text);
        return nullptr;
    };
    if (!emuenv || !app)
        return fail("This game is not installed.");
    const fs::path source = save_folder(*emuenv, *app);
    std::error_code ec;
    if (app->savedata.empty() || !fs::exists(source, ec) || fs::is_empty(source, ec))
        return fail(app->title + " has no save data yet.");

    const fs::path exports = fs::path(ios::get_documents_path()) / "Save Backups";
    fs::create_directories(exports, ec);
    const fs::path zip_path = exports / fmt::format("{} ({}) {}.zip", safe_file_name(app->title), app->title_id, timestamp());

    mz_zip_archive zip{};
    if (!mz_zip_writer_init_file(&zip, zip_path.string().c_str(), 0))
        return fail("Could not create the backup file.");
    bool ok = true;
    for (auto it = fs::recursive_directory_iterator(source, ec); ok && !ec && it != fs::recursive_directory_iterator(); it.increment(ec)) {
        if (!it->is_regular_file(ec))
            continue;
        const std::string name = fs::relative(it->path(), source, ec).generic_string();
        ok = mz_zip_writer_add_file(&zip, name.c_str(), it->path().string().c_str(), nullptr, 0, MZ_BEST_COMPRESSION);
    }
    ok = ok && mz_zip_writer_finalize_archive(&zip);
    mz_zip_writer_end(&zip);
    if (!ok) {
        fs::remove(zip_path, ec);
        return fail("Could not write the backup.");
    }
    LOG_INFO("Exported the save data of {} to {}", app->title_id, zip_path.string());
    if (message)
        *message = dup_string("Saved to Files › Vita3KiOS › Save Backups.");
    return dup_string(zip_path.string());
}

bool v3k_import_save_data(const char *title_id, const char *zip_path, char **message) {
    auto *emuenv = ios::get_emuenv();
    const auto app = app_for(title_id);
    const auto result = [&](bool ok, const std::string &text) {
        if (message)
            *message = dup_string(text);
        return ok;
    };
    if (!emuenv || !app || !zip_path)
        return result(false, "This game is not installed.");
    if (app->savedata.empty())
        return result(false, app->title + " does not use save data.");

    mz_zip_archive zip{};
    if (!mz_zip_reader_init_file(&zip, zip_path, 0))
        return result(false, "That file is not a zip archive.");

    const fs::path target = save_folder(*emuenv, *app);
    std::error_code ec;
    // Keep the current save, just in case
    if (fs::exists(target, ec) && !fs::is_empty(target, ec)) {
        const fs::path backup = emuenv->cache_path / "save-backups" / fmt::format("{}-{}", app->savedata, timestamp());
        fs::create_directories(backup.parent_path(), ec);
        fs::rename(target, backup, ec);
        if (ec) {
            mz_zip_reader_end(&zip);
            return result(false, "Could not move the current save aside: " + ec.message());
        }
    }
    fs::create_directories(target, ec);

    // Archives made by hand often wrap everything in one folder: strip it when every file shares it
    const mz_uint count = mz_zip_reader_get_num_files(&zip);
    std::string prefix;
    for (mz_uint i = 0; i < count; i++) {
        char name[1024];
        mz_zip_reader_get_filename(&zip, i, name, sizeof(name));
        const std::string entry = name;
        const auto slash = entry.find('/');
        const std::string top = slash == std::string::npos ? std::string() : entry.substr(0, slash + 1);
        if (i == 0)
            prefix = top;
        else if (top != prefix)
            prefix.clear();
        if (top.empty() || entry.find("sce_sys/") == 0)
            prefix.clear();
    }

    bool ok = true;
    for (mz_uint i = 0; ok && i < count; i++) {
        if (mz_zip_reader_is_file_a_directory(&zip, i))
            continue;
        char name[1024];
        mz_zip_reader_get_filename(&zip, i, name, sizeof(name));
        std::string entry = std::string(name).substr(prefix.size());
        if (entry.empty() || entry.find("..") != std::string::npos)
            continue;
        const fs::path out = target / entry;
        fs::create_directories(out.parent_path(), ec);
        ok = mz_zip_reader_extract_to_file(&zip, i, out.string().c_str(), 0);
    }
    mz_zip_reader_end(&zip);
    LOG_INFO("Imported save data for {} from {}: {}", app->title_id, zip_path, ok ? "ok" : "failed");
    return result(ok, ok ? "Save data imported. The previous save was kept in the cache folder." : "Some files could not be extracted.");
}

// ---- Game patches (vita3k-patches) ----

bool v3k_download_patches(char **message) {
    auto *emuenv = ios::get_emuenv();
    const auto result = [&](bool ok, const std::string &text) {
        if (message)
            *message = dup_string(text);
        return ok;
    };
    if (!emuenv)
        return result(false, "The emulator is not ready.");
    const std::string xml = net_utils::get_web_response(PATCHLIST_XML_URL);
    PatchEntries entries;
    if (xml.empty())
        return result(false, "Could not download the patch list. Check your connection and try again.");
    if (!parse_patch_entries(xml, entries))
        return result(false, "The downloaded patch list is not valid.");
    std::error_code ec;
    fs::create_directories(emuenv->patch_path, ec);
    const fs::path path = patchlist_xml_path(emuenv->patch_path);
    if (!fs_utils::dump_data(path, xml.data(), static_cast<std::streamsize>(xml.size())))
        return result(false, "Could not save the patch list.");
    return result(true, fmt::format("Downloaded {} patches.", entries.size()));
}

char *v3k_patches_json(const char *title_id) {
    auto *emuenv = ios::get_emuenv();
    if (!emuenv || !title_id)
        return dup_string("[]");
    const auto enabled = load_enabled_patches(emuenv->patch_path);
    const std::string id = title_id;
    std::string json = "[";
    bool first = true;
    for (const auto &entry : load_patch_entries(emuenv->patch_path)) {
        if (std::find(entry.title_ids.begin(), entry.title_ids.end(), id) == entry.title_ids.end())
            continue;
        json += fmt::format(R"({}{{"key":{},"name":{},"author":{},"note":{},"version":{},"appVersion":{},"enabled":{}}})",
            first ? "" : ",", quoted(entry.key()), quoted(entry.name.empty() ? entry.title : entry.name), quoted(entry.author),
            quoted(entry.note), quoted(entry.patch_ver), quoted(entry.app_ver), enabled.contains(entry.key()) ? "true" : "false");
        first = false;
    }
    json += "]";
    return dup_string(json);
}

bool v3k_patches_downloaded(void) {
    auto *emuenv = ios::get_emuenv();
    std::error_code ec;
    return emuenv && fs::exists(patchlist_xml_path(emuenv->patch_path), ec);
}

bool v3k_set_patch_enabled(const char *key, bool enabled) {
    auto *emuenv = ios::get_emuenv();
    if (!emuenv || !key)
        return false;
    auto set = load_enabled_patches(emuenv->patch_path);
    if (enabled)
        set.insert(key);
    else
        set.erase(key);
    return save_enabled_patches(emuenv->patch_path, set);
}
