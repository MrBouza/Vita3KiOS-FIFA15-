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

// Small UIKit/Foundation helpers used by the C++ side of the iOS port

#include "ios_platform.h"

#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#include <cstdint>
#include <mutex>
#include <sys/sysctl.h>
#include <unistd.h>

// Implemented in Swift (ui/LibraryHost.swift)
extern "C" void v3k_ui_show(void);
extern "C" void v3k_ui_hide(void);

// Not in the public SDK headers, but a stable syscall wrapper used by every iOS JIT app
extern "C" int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);

namespace ios {

std::string get_documents_path() {
    @autoreleasepool {
        NSArray<NSURL *> *urls = [[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask];
        return [urls.firstObject.path UTF8String];
    }
}

std::string get_bundle_resources_path() {
    @autoreleasepool {
        return [[NSBundle mainBundle].resourcePath UTF8String];
    }
}

std::string get_os_version() {
    @autoreleasepool {
        UIDevice *device = [UIDevice currentDevice];
        return std::string([device.systemName UTF8String]) + " " + [device.systemVersion UTF8String];
    }
}

std::string get_device_model() {
    // hw.machine gives the model identifier, e.g. "iPhone15,2"
    char machine[64] = {};
    size_t size = sizeof(machine);
    if (sysctlbyname("hw.machine", machine, &size, nullptr, 0) == 0 && machine[0])
        return machine;
    return "Unknown Apple device";
}

namespace {
std::mutex pending_launch_mutex;
std::string pending_launch;
} // namespace

void set_pending_launch(const std::string &title_id) {
    std::lock_guard lock(pending_launch_mutex);
    pending_launch = title_id;
}

std::string run_library_until_launch() {
    {
        std::lock_guard lock(pending_launch_mutex);
        pending_launch.clear();
    }
    v3k_ui_show();
    for (;;) {
        @autoreleasepool {
            // Same pattern SDL uses to pump UIKit events: run the main loop in short slices
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, true);
        }
        std::lock_guard lock(pending_launch_mutex);
        if (!pending_launch.empty()) {
            std::string title_id = pending_launch;
            pending_launch.clear();
            v3k_ui_hide();
            return title_id;
        }
    }
}

// From Tsubomi (vita3k_ios_configure_audio_session)
std::string configure_audio_session() {
    @autoreleasepool {
        NSError *error = nil;
        AVAudioSession *session = AVAudioSession.sharedInstance;
        std::string result;
        // Playback so audio keeps running with the mute switch on; MixWithOthers keeps us polite
        if (![session setCategory:AVAudioSessionCategoryPlayback mode:AVAudioSessionModeDefault
                          options:AVAudioSessionCategoryOptionMixWithOthers error:&error]) {
            result += std::string("setCategory failed: ") + (error.localizedDescription.UTF8String ?: "unknown") + ". ";
            error = nil;
        }
        [session setPreferredSampleRate:48000 error:nil];
        [session setPreferredIOBufferDuration:1024.0 / 48000.0 error:nil];
        if (![session setActive:YES error:&error])
            return result + "Audio session activation failed: " + (error.localizedDescription.UTF8String ?: "unknown");
        return result + "Audio session active (Playback), " + std::to_string(static_cast<int>(session.sampleRate)) + " Hz";
    }
}

bool is_jit_enabled() {
    constexpr unsigned int CS_OPS_STATUS = 0;
    constexpr uint32_t CS_DEBUGGED = 0x10000000;
    uint32_t flags = 0;
    if (csops(getpid(), CS_OPS_STATUS, &flags, sizeof(flags)) != 0)
        return false;
    return (flags & CS_DEBUGGED) != 0;
}

} // namespace ios
