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

// iOS JIT memory.
//
// dynarmic needs memory it can write machine code into and then execute. On iOS that requires a
// debugger to be attached (StikDebug, or LiveContainer's "Launch with JIT"), and on iOS 26 devices
// with TXM (A15+/M2+) the debugger must also prepare every executable region up front, through
// StikDebug's universal.js breakpoint protocol (brk #0xf00d).
//
// So at launch one arena is prepared, a writable alias of it is created, and every dynarmic code
// cache is carved out of it (through oaknut_ios_jit_alloc, see patches/dynarmic-ios-jit.patch).
//
// Keep this header free of Vita3K includes: the implementation uses Mach headers.

#include <cstddef>
#include <functional>
#include <string>

namespace ios {

enum class JitMode {
    None, // no executable memory: games cannot run
    Txm, // iOS 26 TXM path: arena prepared by the debugger script
    Legacy, // debugger attached, classic writable/executable dual mapping
};

struct JitStatus {
    JitMode mode = JitMode::None;
    std::size_t arena_size = 0;
    std::string detail; // human-readable explanation, shown in the UI and the log
};

// Where JIT setup reports its progress (the Vita3K log)
void jit_set_logger(std::function<void(const std::string &)> logger);

// Checks how JIT can be set up, on a background thread. Never stops the app: on iOS 26 it only
// notes whether a JIT script is attached, the request itself waits for jit_request_async().
void jit_init_async();
// True when a JIT script is attached and can be asked for executable memory
bool jit_can_request();
// Asks the attached JIT script for executable memory (iOS 26 TXM). The debugger pauses the whole
// app while it prepares the memory, so the UI shows what is happening before calling this.
void jit_request_async();
bool jit_preparing();
JitStatus jit_status();
bool jit_ready();

// Size of each dynarmic code cache carved from the arena (see cpu/src/dynarmic_cpu.cpp)
constexpr std::size_t jit_code_cache_size = 2 * 1024 * 1024;

} // namespace ios
