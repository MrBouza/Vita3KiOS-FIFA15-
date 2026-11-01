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

// On-screen touch controls: an SDL virtual gamepad (the approach Tsubomi uses) that Vita3K sees like
// any other controller, driven by the SwiftUI overlay in ui/TouchControls.swift. Plain C so Swift
// can call it through the bridging header.

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// Button and axis numbers are SDL_GamepadButton / SDL_GamepadAxis values
bool v3k_pad_attach(void);
void v3k_pad_detach(void);
void v3k_pad_set_button(int button, bool pressed);
// value in -1...1 (triggers 0...1)
void v3k_pad_set_axis(int axis, float value);
void v3k_pad_release_all(void);
// Ends the running game and returns to the library
void v3k_pad_request_exit(void);

#ifdef __cplusplus
}
#endif
