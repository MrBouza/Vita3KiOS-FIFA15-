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

#include <atomic>
#include <cstdint>

// Graphics memory the texture cache holds, for the memory log, and how many times the system said
// memory is low (each one shrinks the texture cache's budget).
namespace gpu_memory {

inline std::atomic<uint64_t> &texture_bytes() {
    static std::atomic<uint64_t> value{ 0 };
    return value;
}

inline std::atomic<uint32_t> &texture_count() {
    static std::atomic<uint32_t> value{ 0 };
    return value;
}

inline std::atomic<uint64_t> &texture_budget() {
    static std::atomic<uint64_t> value{ 0 };
    return value;
}

inline std::atomic<uint32_t> &pressure() {
    static std::atomic<uint32_t> value{ 0 };
    return value;
}

} // namespace gpu_memory
