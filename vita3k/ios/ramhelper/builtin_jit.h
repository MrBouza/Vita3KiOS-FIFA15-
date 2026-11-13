// Vita3K project
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

// Built-in JIT: a helper extension process attaches a debugger to Hinoki with StikJIT, using the
// player's pairing file, so no JIT app is needed (LocalDevVPN still has to be connected).

#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Why built-in JIT can't run here (inside LiveContainer, no helper extension, no get-task-allow,
// iOS older than 17.4), or NULL when it can
const char *v3k_builtin_jit_unavailable_reason(void);

// Starts a helper and has it enable JIT for this process. Returns at once; `progress` gets status lines
// and `done` the result (message NULL on success), both on a background queue. `script_base64`: the
// JIT script to run (NULL: StikJIT's own universal script); `force_script`: run it even where the
// device's security wouldn't need one.
void v3k_builtin_jit_start(const uint8_t *pairing, size_t pairing_length, const char *script_base64, bool force_script,
    void (*progress)(const char *text), void (*done)(bool ok, const char *message));

// An attach is running
bool v3k_builtin_jit_busy(void);

#ifdef __cplusplus
}
#endif
