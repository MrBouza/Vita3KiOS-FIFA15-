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

// Plain C interface between the SwiftUI frontend and the Vita3K core.
// It plays the same role as the JNI functions in vita3k/android/jni/ do for the Android UI.
// Strings returned as char * are heap-allocated: release them with v3k_free_string.

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---- Status ----
const char *v3k_version(void);
// True once the JIT arena is prepared and passed its self-test
bool v3k_is_jit_enabled(void);
// Why JIT is or isn't available, for the UI (free with v3k_free_string)
char *v3k_jit_status_text(void);
// True while JIT is being checked or set up
bool v3k_jit_preparing(void);
// True when a JIT script is attached and v3k_jit_request can set up JIT (iOS 26)
bool v3k_jit_can_request(void);
// Asks the JIT script for executable memory; the app pauses while the debugger works
void v3k_jit_request(void);
const char *v3k_storage_path(void);

// Bit 0: preinstalled package, bit 1: main firmware, bit 2: font package
int v3k_firmware_state(void);

// ---- Library ----
// JSON array: [{"titleId","title","version","category","iconPath","path"}]
char *v3k_apps_json(void);
void v3k_refresh_apps(void);
bool v3k_delete_app(const char *title_id);
void v3k_free_string(char *str);

// ---- Installing ----
typedef void (*v3k_progress_fn)(void *context, float percent);

// What kind of thing a path is: 0 unknown, 1 firmware (.PUP), 2 archive (.vpk/.zip), 3 package (.pkg), 4 folder
int v3k_install_kind(const char *path);

// Installs firmware, a .vpk/.zip, a .pkg (zrif may be NULL or empty when a license is already present),
// or a folder (a game folder, or a folder holding any of the above). Blocking: call it off the main thread.
// On return *message (if not NULL) holds a human-readable summary to free with v3k_free_string.
bool v3k_install(const char *path, const char *zrif, v3k_progress_fn progress, void *context, char **message);

// Reads the zRIF stored next to a package (GAME.pkg -> GAME.zrif), or NULL
char *v3k_zrif_next_to(const char *pkg_path);

// ---- Settings ----
// JSON object with the values used by the settings screen
char *v3k_settings_json(void);
// Keys: "resolution-multiplier" (float), "anisotropic-filtering" (int), "audio-volume" (int),
// "screen-filter" (string), and booleans "v-sync", "cpu-opt", "ngs-enable", "high-accuracy",
// "stretch-display", "performance-overlay", "texture-cache", "turbo-mode", "pstv-mode"
bool v3k_set_setting_number(const char *key, double value);
bool v3k_set_setting_bool(const char *key, bool value);
bool v3k_set_setting_string(const char *key, const char *value);

// ---- Launching ----
// Asks the app loop to close the library and boot this title
void v3k_request_launch(const char *title_id);

#ifdef __cplusplus
}
#endif
