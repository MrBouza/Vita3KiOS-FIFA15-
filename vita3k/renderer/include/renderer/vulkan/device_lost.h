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

#include <util/log.h>

#include <vulkan/vulkan.hpp>

#include <atomic>
#include <cstdint>
#include <type_traits>

namespace renderer::vulkan {

// Apple (MoltenVK): a GPU error in one command buffer (a fault or a timeout) makes the next fence
// wait, submit or present report VK_ERROR_DEVICE_LOST. With MVK_CONFIG_RESUME_LOST_DEVICE (set in
// renderer.cpp) the device keeps working, but vulkan-hpp turns the error into an exception, and the
// uncaught exception ended the whole app (Uncharted: Golden Abyss on an A15). On Apple, log it and
// carry on as if the call had finished: at worst one frame is wrong. Elsewhere it stays fatal.
inline uint32_t count_device_lost(const char *where) {
    static std::atomic<uint32_t> count{ 0 };
    const uint32_t n = ++count;
    if (n <= 5 || (n & (n - 1)) == 0)
        LOG_ERROR("GPU error (device lost) during {}; continuing ({} so far)", where, n);
    return n;
}

template <typename F>
auto tolerate_device_lost(const char *where, F &&call) -> decltype(call()) {
    using Result = decltype(call());
#ifdef __APPLE__
    try {
        return call();
    } catch (const vk::DeviceLostError &) {
        count_device_lost(where);
        if constexpr (std::is_same_v<Result, vk::Result>)
            return vk::Result::eSuccess;
        else if constexpr (!std::is_void_v<Result>)
            return Result{};
    }
#else
    return call();
#endif
}

} // namespace renderer::vulkan
