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

#include <chrono>

#include <vkutil/objects.h>

#include "screen_filters.h"

#include <atomic>
#include <memory>
#include <mutex>
#include <string>

namespace renderer::vulkan {

struct VKState;

#ifdef __ANDROID__
bool has_android_surface();
#endif

class ScreenRenderer {
public:
    VKState &state;

    vk::SurfaceKHR surface;
    vk::SwapchainKHR swapchain;

    vk::SurfaceCapabilitiesKHR surface_capabilities;
    vk::SurfaceFormatKHR surface_format;
    vk::PresentModeKHR present_mode{};
    // V-Sync on: the mode picked at start (FIFO on iOS: frames wait for the screen). Off: a mode that
    // doesn't wait if the device has one, and in any case a frame is skipped instead of waiting when
    // the screen has no image free, so the game never waits on the display
    vk::PresentModeKHR vsync_on_mode{};
    vk::PresentModeKHR vsync_off_mode{};
    bool vsync = true;
    void set_vsync(bool enabled);
    // V-Sync off: when the frames already handed to the screen will keep it busy until (MoltenVK takes
    // no timeout and would block in nextDrawable once every drawable is queued)
    std::chrono::steady_clock::time_point screen_busy_until{};
    // With present wait (VKState::support_present_wait): the id of the last frame handed to the screen,
    // counted from 1 for each swapchain
    uint64_t last_present_id = 0;
    uint64_t next_present_id = 1;
    VkSwapchainKHR present_id_swapchain = VK_NULL_HANDLE;
    // frames skipped in a row since then: never longer than a quarter second (a screen that stopped
    // reporting must not leave the game without a picture)
    std::chrono::steady_clock::time_point skipping_since{};
    // How many frames already handed to the screen are still waiting to be shown (at least `frames`)
    bool screen_has_queued(uint32_t frames);
    vk::Extent2D extent;
    uint32_t swapchain_size{};
    std::vector<vk::Image> swapchain_images;
    std::vector<vk::ImageView> swapchain_views;
    std::vector<vk::Framebuffer> swapchain_framebuffers;
    std::vector<vk::CommandBuffer> command_buffers;
    std::vector<vk::Fence> fences;
    std::vector<vk::Semaphore> image_acquired_semaphores;
    std::vector<vk::Semaphore> image_ready_semaphores;

    // renderpass used when no effect is done previously (clear the swapchain content)
    vk::RenderPass default_render_pass;
    // renderpass used after a post-processing pass clearing the swapchain, compatible with the default render pass
    vk::RenderPass post_filter_render_pass;
#ifdef __ANDROID__
    // renderpass used to (partially) prevent a driver bug using stock adreno drivers
    vk::RenderPass stock_adreno_pass;
#endif

    std::unique_ptr<ScreenFilter> filter;

    std::vector<vkutil::Image> vita_surface;
    vma::Allocation vita_surface_staging_alloc;
    vma::AllocationInfo vita_surface_staging_info;
    vk::Buffer vita_surface_staging;

    vk::CommandBuffer current_cmd_buffer;

    // these are used by the gui
    uint32_t swapchain_image_idx = ~0;
    // between 0 and swapchain_size - 1, used as the index for semaphores
    int current_frame = 0;
    // set when the swapchain needs to be rebuilt before the next acquire
    bool need_rebuild = false;
    // set when we also need to recreate the surface before rebuilding swapchain
    bool need_surface_recreate = false;

    ScreenRenderer(VKState &state);

    bool create();
    // called after the logical device has been created
    bool setup();
    void cleanup();

    bool acquire_swapchain_image();
    void begin_default_render_pass();
    void render(vk::ImageView image_view, vk::ImageLayout layout, const Viewport &viewport);
    void swap_window();
    void set_filter(const std::string_view &filter);
    // While the phone is hot: the costly upscalers (FSR, Bicubic, FXAA) give way to bilinear, and come back
    // once it has cooled down
    void follow_thermal_filter(bool cool_down);
    std::string filter_before_cooling;

private:
    void create_render_pass();
    void create_layout_sync();
    void renew_semaphores();
    void create_swapchain();
    vk::Pipeline create_graphics_pipeline_impl(std::array<vk::PipelineShaderStageCreateInfo, 2> &shader_stages);
    bool create_graphics_pipelines();
    void copy_to_vao(const void *data);
    void create_surface_image();
    void destroy_swapchain();
    // Destroys the surface through whatever made it
    void destroy_surface();
    bool ensure_swapchain();
    bool rebuild_swapchain_if_visible();
    bool surface_matches_window_size();
};
} // namespace renderer::vulkan
