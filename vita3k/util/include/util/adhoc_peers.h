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

#include <algorithm>
#include <atomic>
#include <cstdint>
#include <mutex>
#include <vector>

// Ad hoc play without broadcasts. A PS Vita finds the other players of a local game by broadcasting
// on the wireless network. iOS drops broadcast and multicast packets from apps that don't hold
// Apple's multicast entitlement (which a sideloaded app can't get), so every packet a game
// broadcasts is also sent to each known player directly. A player is known once one packet from it
// arrives, or when its IP address is typed into Settings › Multiplayer: one phone typing the other's
// address is enough, the other learns the first from its packets.
// Addresses are IPv4 in network byte order.
namespace adhoc_peers {

inline std::mutex &mutex() {
    static std::mutex m;
    return m;
}

inline std::vector<uint32_t> &list() {
    static std::vector<uint32_t> peers;
    return peers;
}

inline std::atomic<uint32_t> &own_addr() {
    static std::atomic<uint32_t> value{ 0 };
    return value;
}

inline std::atomic<uint32_t> &broadcast_addr() {
    static std::atomic<uint32_t> value{ 0xFFFFFFFF };
    return value;
}

// Addresses typed in the app's settings (set by the platform layer, read when ad hoc starts)
inline std::vector<uint32_t> (*&configured())() {
    static std::vector<uint32_t> (*fn)() = nullptr;
    return fn;
}

inline bool is_broadcast(uint32_t addr) {
    return addr == 0xFFFFFFFF || addr == broadcast_addr().load(std::memory_order_relaxed);
}

// Returns true when the address was new
inline bool add(uint32_t addr) {
    if (addr == 0 || is_broadcast(addr) || addr == own_addr().load(std::memory_order_relaxed))
        return false;
    // 127.x.x.x
    if ((addr & 0xFF) == 127)
        return false;
    const std::lock_guard<std::mutex> lock(mutex());
    auto &peers = list();
    if (std::find(peers.begin(), peers.end(), addr) != peers.end())
        return false;
    peers.push_back(addr);
    return true;
}

inline std::vector<uint32_t> snapshot() {
    const std::lock_guard<std::mutex> lock(mutex());
    return list();
}

// Called when ad hoc starts: our own address, the network's broadcast address, then the typed ones
inline void start(uint32_t own, uint32_t broadcast) {
    own_addr() = own;
    broadcast_addr() = broadcast;
    {
        const std::lock_guard<std::mutex> lock(mutex());
        list().clear();
    }
    if (configured())
        for (const uint32_t addr : configured()())
            add(addr);
}

} // namespace adhoc_peers
