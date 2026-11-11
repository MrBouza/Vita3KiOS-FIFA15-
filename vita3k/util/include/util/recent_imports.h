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

#include <array>
#include <atomic>
#include <cstdint>
#include <string>

#include <fmt/format.h>

// The last system calls games made, kept so a crash report can say what a thread did just before it
// went wrong. Recording is one atomic add and one store per call.
namespace recent_imports {

constexpr uint32_t COUNT = 64;

inline std::atomic<uint32_t> next{ 0 };
inline std::array<std::atomic<uint64_t>, COUNT> calls{};
// Set by the modules library: NID to name
inline const char *(*namer)(uint32_t nid) = nullptr;

inline void record(int thread_id, uint32_t nid, uint32_t lr) {
    const uint32_t slot = next.fetch_add(1, std::memory_order_relaxed) % COUNT;
    // thread id (8 bits) | caller (24 bits of the return address, enough to find it) | nid
    calls[slot].store((static_cast<uint64_t>(thread_id & 0xFF) << 56) | (static_cast<uint64_t>(lr & 0xFFFFFF) << 32) | nid, std::memory_order_relaxed);
}

// Oldest first; only this thread's calls when thread_id >= 0
inline std::string describe(int thread_id, uint32_t max = 24) {
    std::string out;
    const uint32_t end = next.load(std::memory_order_relaxed);
    const uint32_t first = end > COUNT ? end - COUNT : 0;
    uint32_t shown = 0;
    for (uint32_t i = end; i-- > first && shown < max;) {
        const uint64_t v = calls[i % COUNT].load(std::memory_order_relaxed);
        if (!v)
            continue;
        const int tid = static_cast<int>(v >> 56);
        if (thread_id >= 0 && tid != (thread_id & 0xFF))
            continue;
        const uint32_t nid = static_cast<uint32_t>(v);
        const char *name = namer ? namer(nid) : nullptr;
        out = fmt::format("  {} (0x{:08X}) from ..{:06X}\n", name ? name : "?", nid, static_cast<uint32_t>(v >> 32) & 0xFFFFFF) + out;
        ++shown;
    }
    return out.empty() ? std::string("  (none)\n") : out;
}

} // namespace recent_imports
