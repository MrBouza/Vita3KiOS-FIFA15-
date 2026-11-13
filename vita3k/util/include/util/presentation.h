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

// How frames reach the screen, set by the platform layer and read by the screen renderer
namespace presentation {

// The game is shown on a TV or other display (iOS TV mode): every frame queued for the display adds
// latency on top of the stream to it, so at most one frame waits for the screen and a newer frame
// replaces rather than queues behind it
inline std::atomic<bool> &low_latency() {
    static std::atomic<bool> value{ false };
    return value;
}

} // namespace presentation
