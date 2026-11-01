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

// Platform queries implemented in Objective-C++ (ios_platform.mm).
// Keep this header free of Vita3K includes: Apple's headers define names such as Ptr
// that clash with Vita3K's own, so the .mm side must never see both.

#include <string>

namespace ios {

std::string get_documents_path();
std::string get_bundle_resources_path();
std::string get_os_version();
std::string get_device_model();

} // namespace ios
