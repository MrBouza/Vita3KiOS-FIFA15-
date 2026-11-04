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

#if defined(VITA3K_PLATFORM_IOS)
#include <pthread.h>
#include <sys/qos.h>
#endif

// How hard the emulator's threads ask the phone for speed. The iOS app sets both flags: "Keep the
// phone cool" (a setting, on by default) and whether iOS reports the phone as hot right now.
namespace thermal {

inline std::atomic<bool> &keep_cool() {
    static std::atomic<bool> value{ true };
    return value;
}

inline std::atomic<bool> &phone_is_hot() {
    static std::atomic<bool> value{ false };
    return value;
}

#if defined(VITA3K_PLATFORM_IOS)
// Game threads. User-interactive (the class of the UI thread) makes iOS raise the performance cores
// to their top clocks for every one of a game's 10 to 20 threads, most of which are background work
// (streaming, audio, loading): that is where the heat came from. User-initiated still runs them on the
// performance cores, without the race to the highest clock.
inline qos_class_t game_thread_qos() {
    return keep_cool().load(std::memory_order_relaxed) ? QOS_CLASS_USER_INITIATED : QOS_CLASS_USER_INTERACTIVE;
}

// The renderer's own threads, called once per loop: full priority, one step down while the phone is
// hot and the player wants it kept cool. `current` starts at 0 (user-interactive, set at thread start).
inline void follow_render_qos(int &current) {
    const int wanted = keep_cool().load(std::memory_order_relaxed) && phone_is_hot().load(std::memory_order_relaxed) ? 1 : 0;
    if (wanted == current)
        return;
    pthread_set_qos_class_self_np(wanted ? QOS_CLASS_USER_INITIATED : QOS_CLASS_USER_INTERACTIVE, 0);
    current = wanted;
}
#endif

} // namespace thermal
