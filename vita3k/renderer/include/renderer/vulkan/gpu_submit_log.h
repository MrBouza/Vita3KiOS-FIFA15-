// TEMPORARY DIAGNOSTIC (dialog GPU hang): remembers the last GPU submissions (game scenes and screen
// frames) so that when the GPU stops finishing work, the log shows which submission is stuck.
#pragma once

#include <vkutil/vkutil.h>
#include <util/log.h>

#include <array>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <mutex>

namespace renderer::vulkan::gpu_log {

struct Entry {
    uint64_t seq = 0;
    VkFence fence = VK_NULL_HANDLE;
    int64_t ms = 0;
    char kind = 0; // 'S' game scene, 'P' screen frame
    uint32_t surface = 0;
    uint32_t width = 0;
    uint32_t height = 0;
    uint32_t extra = 0;
};

inline std::mutex mutex;
inline std::array<Entry, 96> ring{};
inline uint64_t next_seq = 0;
inline std::atomic<bool> dumped{ false };

inline int64_t now_ms() {
    return std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now().time_since_epoch()).count();
}

inline void record(vk::Fence fence, char kind, uint32_t surface, uint32_t width, uint32_t height, uint32_t extra) {
    std::lock_guard<std::mutex> lock(mutex);
    ring[next_seq % ring.size()] = Entry{ next_seq, static_cast<VkFence>(fence), now_ms(), kind, surface, width, height, extra };
    next_seq++;
}

// Once per session: every submission of the last 2.5 s, oldest first, with whether the GPU finished it
inline void dump(vk::Device device, const char *why) {
    if (dumped.exchange(true))
        return;
    std::lock_guard<std::mutex> lock(mutex);
    const int64_t now = now_ms();
    LOG_INFO("GPU submissions ({}): oldest first, S = game scene, P = frame for the screen", why);
    const uint64_t first = next_seq > ring.size() ? next_seq - ring.size() : 0;
    for (uint64_t seq = first; seq < next_seq; seq++) {
        const Entry &e = ring[seq % ring.size()];
        if (now - e.ms > 2500 || e.fence == VK_NULL_HANDLE)
            continue;
        const VkResult status = VULKAN_HPP_DEFAULT_DISPATCHER.vkGetFenceStatus(static_cast<VkDevice>(device), e.fence);
        const char *state = status == VK_SUCCESS ? "done" : status == VK_NOT_READY ? "NOT DONE" : "error";
        if (e.kind == 'S')
            LOG_INFO("  #{} {} ms ago: scene into 0x{:X} ({}x{}), {} command buffers: {}", e.seq, now - e.ms, e.surface, e.width, e.height, e.extra, state);
        else
            LOG_INFO("  #{} {} ms ago: screen frame (image {}, {}x{}, game frame 0x{:X}): {}", e.seq, now - e.ms, e.extra, e.width, e.height, e.surface, state);
    }
}

} // namespace renderer::vulkan::gpu_log
