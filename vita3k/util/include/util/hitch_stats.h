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

// Diagnostics for stutter and freezes (FIFA 15 investigation).
//
// - Every HLE import call is timed. The thread that presents frames (_sceDisplaySetFrameBuf) keeps a
//   per-frame tally: time spent inside HLE calls, and its three longest calls. A frame slower than
//   HITCH_THRESHOLD_MS is logged with that tally and with the global counters below, so a hitch can be
//   pinned on "waiting in an HLE call", "memory faults", "pipeline compiles" or "guest code itself".
// - Every guest thread keeps a ring of its last imports (name, return value, caller). It is dumped when
//   the thread touches memory it should not (null page, unallocated memory) or is stopped, so a freeze
//   can be traced to the HLE call whose result sent the game off the rails.

#include <array>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <string>

#include <fmt/format.h>

namespace hitch {

constexpr uint64_t HITCH_THRESHOLD_MS = 50;

inline uint64_t now_ns() {
    const auto since_epoch = std::chrono::steady_clock::now().time_since_epoch();
    return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::nanoseconds>(since_epoch).count());
}

// Global counters, read and reset by the frame logger (any thread may add to them)
inline std::atomic<uint64_t> faults{ 0 }; // access violations handled (write tracking, page release)
inline std::atomic<uint64_t> fault_ns{ 0 }; // time spent handling them
inline std::atomic<uint64_t> sync_pipelines{ 0 }; // pipelines compiled on the render thread (blocking)
inline std::atomic<uint64_t> sync_pipeline_ns{ 0 };
inline std::atomic<uint64_t> async_pipelines{ 0 }; // pipelines handed to the async compiler

// Set by the module layer: resolves an import NID to its name
using ImportNameFn = const char *(*)(uint32_t nid);
inline std::atomic<ImportNameFn> import_name_fn{ nullptr };

inline const char *name_of(uint32_t nid) {
    const ImportNameFn fn = import_name_fn.load(std::memory_order_relaxed);
    const char *name = fn ? fn(nid) : nullptr;
    return name ? name : "?";
}

struct ImportRecord {
    uint32_t nid = 0;
    uint32_t ret = 0; // r0 after the call
    uint32_t lr = 0; // where the game called it from
    uint32_t us = 0; // duration in microseconds
};

constexpr size_t RECENT_IMPORTS = 24;

struct ThreadImports {
    std::array<ImportRecord, RECENT_IMPORTS> ring{};
    size_t next = 0;
    size_t count = 0;

    // per-frame tally (only meaningful on the thread that presents frames)
    uint64_t frame_hle_ns = 0;
    uint64_t frame_calls = 0;
    std::array<ImportRecord, 3> frame_top{};

    void add(const ImportRecord &record) {
        ring[next] = record;
        next = (next + 1) % RECENT_IMPORTS;
        if (count < RECENT_IMPORTS)
            count++;

        frame_hle_ns += static_cast<uint64_t>(record.us) * 1000;
        frame_calls++;
        // keep the three longest calls of the frame, longest first
        for (size_t i = 0; i < frame_top.size(); i++) {
            if (record.us > frame_top[i].us) {
                for (size_t j = frame_top.size() - 1; j > i; j--)
                    frame_top[j] = frame_top[j - 1];
                frame_top[i] = record;
                break;
            }
        }
    }

    void reset_frame() {
        frame_hle_ns = 0;
        frame_calls = 0;
        frame_top = {};
    }
};

inline ThreadImports &this_thread_imports() {
    thread_local ThreadImports imports;
    return imports;
}

// "sceFoo -> 0x0 from 0x81001234 (12 us), ..." oldest first
inline std::string recent_imports() {
    const ThreadImports &imports = this_thread_imports();
    if (imports.count == 0)
        return "none on this thread";
    std::string out;
    const size_t first = (imports.next + RECENT_IMPORTS - imports.count) % RECENT_IMPORTS;
    for (size_t i = 0; i < imports.count; i++) {
        const ImportRecord &r = imports.ring[(first + i) % RECENT_IMPORTS];
        out += fmt::format("\n    {} -> 0x{:X} from 0x{:X} ({} us)", name_of(r.nid), r.ret, r.lr, r.us);
    }
    return out;
}

inline std::string describe(const ImportRecord &r) {
    return fmt::format("{} {:.1f} ms (-> 0x{:X})", name_of(r.nid), r.us / 1000.0, r.ret);
}

} // namespace hitch
