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

#include "io/functions.h"
#include "io/io.h"

#include <modules/module_parent.h>

#include <cpu/functions.h>
#include <emuenv/state.h>
#include <io/device.h>
#include <io/state.h>
#include <io/vfs.h>
#include <kernel/load_self.h>
#include <kernel/state.h>
#include <kernel/types.h>
#include <mem/functions.h>
#include <mem/ptr.h>
#include <module/load_module.h>
#include <net/relay.h>
#include <nids/functions.h>
#include <packages/license.h>
#include <packages/sce_types.h>
#include <util/find.h>
#include <util/lock_and_find.h>
#include <util/log.h>
#include <util/recent_imports.h>
#include <util/string_utils.h>
#include <util/thermal.h>

#include <algorithm>
#include <atomic>
#include <map>
#include <mutex>
#include <string_view>
#include <unordered_map>
#include <unordered_set>
#include <vector>

static constexpr bool LOG_UNK_NIDS_ALWAYS = false;

// Ad hoc matching: sceNetAdhocMatchingSelectTarget (invite a player, or accept their invite)
// returns 0x8041310F when that player is already mid-handshake: state 4, we already sent them a
// request, or state 3, we already accepted theirs. Over the network a handshake takes long enough
// for a second tap on the same player to land inside it, and the error makes some games (Nidhogg)
// drop ad hoc. A second invite is made to succeed, since it changes nothing. A tap after accepting
// still fails (with 0x80413110): games such as Nidhogg treat a successful select-target as "I
// invited", which would make both players the guest and the match would never start.
// Only applied when the bytes are exactly the ones in firmware 3.74's adhoc_matching.suprx
// (segment 0 offset 0x720: movw r4, #0x310F; movt r4, #0x8041).
static void patch_adhoc_matching(MemState &mem, const SceKernelModuleInfo &info) {
    if (std::string(info.module_name) != "SceNetAdhocMatching")
        return;
    constexpr uint32_t OFFSET = 0x720;
    static constexpr uint8_t expected[8] = { 0x43, 0xF2, 0x0F, 0x14, 0xC8, 0xF2, 0x41, 0x04 };
    // At this point r3 holds the target's state minus 1. State 4 (we already sent this target a request):
    // succeed, as a second tap on the same player changes nothing. State 3 (we already accepted this
    // target's request): fall through to the state-5 error (0x80413110), so the game stays the host
    // instead of treating the tap as its own invite.
    //   cmp r3, #3 / bne +4 (state-5 error) / movs r4, #0 / b +8 (return)
    static constexpr uint8_t replacement[8] = { 0x03, 0x2B, 0x02, 0xD1, 0x00, 0x24, 0x04, 0xE0 };
    const auto &seg = info.segments[0];
    const auto base = seg.vaddr.cast<uint8_t>();
    if (!base || seg.memsz < OFFSET + sizeof(expected)) {
        LOG_WARN("Ad hoc matching: module layout not as expected, select-target patch not applied");
        return;
    }
    uint8_t *code = base.get(mem) + OFFSET;
    if (memcmp(code, expected, sizeof(expected)) != 0) {
        LOG_WARN("Ad hoc matching: different module version, select-target patch not applied");
        return;
    }
    memcpy(code, replacement, sizeof(replacement));
    LOG_INFO("Ad hoc matching: selecting a player we already invited now succeeds instead of failing with 0x8041310F");
}

#define LIBRARY(name) extern const LibraryInitFn import_library_init_##name;
#include <modules/library_init_list.inc>
#undef LIBRARY

#define VAR_NID(name, nid) extern const ImportVarFactory import_##name;
#define NID(name, nid) extern const ImportFn import_##name;
#include <nids/nids.inc>
#undef NID
#undef VAR_NID

struct EmuEnvState;

static const ImportFn *resolve_import(uint32_t nid) {
    switch (nid) {
#define VAR_NID(name, nid)
#define NID(name, nid) \
    case nid:          \
        return &import_##name;
#include <nids/nids.inc>
#undef NID
#undef VAR_NID
    default:
        return nullptr;
    }
}

bool has_hle_implementation(uint32_t nid) {
    return resolve_import(nid) != nullptr;
}

struct VarExport {
    uint32_t nid;
    ImportVarFactory factory;
};

void init_exported_vars(EmuEnvState &emuenv) {
    const auto var_exports = std::to_array<VarExport>({
#define NID(name, nid)
#define VAR_NID(name, nid) \
    {                      \
        nid,               \
        import_##name      \
    },
#include <nids/nids.inc>
#undef VAR_NID
#undef NID
    });

    for (const auto &var : var_exports) {
        auto addr = var.factory(emuenv);
        emuenv.kernel.export_nids.emplace(var.nid, addr);
    }
}

Ptr<void> create_vtable(const std::vector<uint32_t> &nids, MemState &mem) {
    // we need 4 bytes for the function pointer and 12 bytes for the syscall
    const uint32_t vtable_size = nids.size() * 4 * sizeof(uint32_t);
    Ptr<void> vtable = Ptr<void>(alloc(mem, vtable_size, "vtable"));
    uint32_t *function_pointer = vtable.cast<uint32_t>().get(mem);
    uint32_t *function_svc = function_pointer + nids.size();
    uint32_t function_location = vtable.address() + nids.size() * sizeof(uint32_t);
    for (uint32_t nid : nids) {
        *function_pointer = function_location;
        // encode svc call
        function_svc[0] = 0xef000000; // svc #0 - Call our interrupt hook.
        function_svc[1] = 0xe1a0f00e; // mov pc, lr - Return to the caller.
        function_svc[2] = nid; // Our interrupt hook will read this.

        function_pointer++;
        function_svc += 3;
        function_location += 3 * sizeof(uint32_t);
    }
    return vtable;
}

Ptr<void> get_client_vtable(KernelState &kernel, MemState &mem) {
    if (!kernel.client_vtable) {
        kernel.client_vtable = create_vtable({
                                                 0x101C93F8, // destroy
                                                 0xA22C3E01, // connect
                                                 0xEC73331C, // disconnect
                                                 0xD484D36D, // terminateConnection
                                                 0x28BD5F19, // invokeSyncMethod
                                                 0x73C72FBB, // invokeSyncMethod
                                                 0xAFD10F3B, // invokeAsyncMethod
                                                 0x387AFA3F, // invokeAsyncMethod
                                                 0xF8C2B8BA, // tryGetResult
                                                 0x4EBB01A2, // tryGetResult
                                                 0x8FF23C3C, // pollEventFlag
                                                 0x45C32034, // waitEventFlag
                                                 0x004F48ED, // getUserData
                                                 0xA3E650B0, // getMsg
                                                 0x60EFADE7, // tryGetMsg
                                                 0xA5AA193C, // ~Client
                                             },
            mem);
    }

    return kernel.client_vtable;
}

static void log_import_call(char emulation_level, uint32_t nid, SceUID thread_id, const std::unordered_set<uint32_t> &nid_blacklist, Address lr) {
    if (!nid_blacklist.contains(nid)) {
        const char *const name = import_name(nid);
        LOG_TRACE("[{}LE] TID: {:<3} FUNC: {} {} at {}", emulation_level, thread_id, log_hex(nid), name, log_hex(lr));
    }
}

// Write watch (util/recent_imports.h): logs the watched words the first time, then every change, and
// whether it came from guest code (seen "before" a call) or from the system call itself ("inside")
static void check_watch(EmuEnvState &emuenv, uint32_t nid, SceUID thread_id, const char *when) {
    static std::mutex watch_mutex;
    static std::vector<uint32_t> last;
    const uint32_t begin = write_watch::begin.load() & ~3u;
    const uint32_t end = write_watch::end.load();
    if (end <= begin || !is_valid_addr_range(emuenv.mem, begin, end))
        return;
    std::vector<uint32_t> now((end - begin) / 4);
    for (size_t i = 0; i < now.size(); i++)
        now[i] = *Ptr<uint32_t>(begin + static_cast<uint32_t>(i) * 4).get(emuenv.mem);
    const std::lock_guard lock(watch_mutex);
    if (now == last)
        return;
    std::string words;
    for (size_t i = 0; i < now.size(); i++)
        words += fmt::format("{}{:08X}{}", i % 8 ? " " : (i ? "\n  " : "  "), now[i], (!last.empty() && last[i] != now[i]) ? "*" : "");
    const char *name = import_name(nid);
    LOG_CRITICAL("Watch: 0x{:08X}..0x{:08X} {} at {} {} (thread {}), changed words marked *:\n{}", begin, end,
        last.empty() ? "first seen" : "changed", when, name ? name : "?", thread_id, words);
    last = std::move(now);
}

// Call trace (ad hoc diagnostics). While a trace window is open (net/relay.h: a new or changed
// gameplay message was just sent or received), every system call is counted, the first calls of
// each function and every change in what it returns are logged, and a summary is written when the
// window closes. Outside the windows, network and NP calls that return an error are logged (a few
// per function and error code).
namespace call_trace {
struct Stats {
    uint64_t count = 0;
    uint64_t errors = 0;
    uint32_t last_ret = 0;
    std::map<SceUID, uint64_t> threads;
};
static std::mutex mutex;
static std::atomic<bool> window_open{ false };
static int64_t window_start = 0;
static std::string window_reasons;
static std::map<uint32_t, Stats> stats;
static uint32_t lines = 0;
static std::map<std::pair<uint32_t, uint32_t>, uint32_t> errors_logged;
constexpr uint32_t MAX_LINES = 400;

static bool is_error(uint32_t ret) {
    return ret >= 0x80000000u;
}

static std::string thread_name(EmuEnvState &emuenv, SceUID thread_id) {
    const ThreadStatePtr thread = emuenv.kernel.get_thread(thread_id);
    return thread ? thread->name : std::string("?");
}

static void close_window(EmuEnvState &emuenv, int64_t now) {
    std::map<uint32_t, Stats> done;
    std::string reasons;
    int64_t start = 0;
    {
        const std::lock_guard lock(mutex);
        if (!window_open)
            return;
        window_open = false;
        done.swap(stats);
        reasons.swap(window_reasons);
        start = window_start;
        lines = 0;
    }
    std::vector<std::pair<uint32_t, Stats>> sorted(done.begin(), done.end());
    std::sort(sorted.begin(), sorted.end(), [](const auto &a, const auto &b) { return a.second.count > b.second.count; });
    std::string text;
    for (const auto &[nid, st] : sorted) {
        const char *name = import_name(nid);
        std::string threads;
        for (const auto &[tid, n] : st.threads)
            threads += fmt::format("{}{} x{}", threads.empty() ? "" : ", ", thread_name(emuenv, tid), n);
        text += fmt::format("\n  {:>6}  {} ({}): last returned 0x{:08X}{}, threads: {}", st.count, name ? name : "?", log_hex(nid), st.last_ret,
            st.errors ? fmt::format(", {} errors", st.errors) : std::string(), threads);
    }
    LOG_INFO("Call trace: window closed after {} ms (opened by: {}). {} functions called, most frequent first:{}", now - start, reasons, sorted.size(), text);
}

static void record(EmuEnvState &emuenv, uint32_t nid, SceUID thread_id, Address lr, const uint32_t (&args)[4], uint32_t ret) {
    const int64_t deadline = net_relay::trace_window_deadline();
    const int64_t now = deadline ? net_relay::steady_now_ms() : 0;
    if (deadline && now < deadline) {
        bool log_it = false;
        bool opened = false;
        std::string reasons;
        uint64_t nth = 0;
        {
            const std::lock_guard lock(mutex);
            if (!window_open) {
                window_open = true;
                window_start = now;
                opened = true;
            }
            const std::string more = net_relay::take_trace_reasons();
            if (!more.empty()) {
                window_reasons += (window_reasons.empty() ? "" : "; ") + more;
                reasons = more;
            }
            Stats &st = stats[nid];
            nth = ++st.count;
            st.threads[thread_id]++;
            if (is_error(ret))
                st.errors++;
            log_it = (nth <= 3 || ret != st.last_ret) && lines < MAX_LINES;
            st.last_ret = ret;
            if (log_it)
                lines++;
        }
        if (opened)
            LOG_INFO("Call trace: window opened ({})", reasons);
        else if (!reasons.empty())
            LOG_INFO("Call trace: window extended ({})", reasons);
        if (log_it) {
            const char *name = import_name(nid);
            LOG_INFO("Call trace: +{} ms {} #{} on {} at {}: args {:08X} {:08X} {:08X} {:08X} -> 0x{:08X}", now - window_start, name ? std::string(name) : log_hex(nid), nth,
                thread_name(emuenv, thread_id), log_hex(lr), args[0], args[1], args[2], args[3], ret);
        }
        return;
    }
    if (deadline && window_open)
        close_window(emuenv, now);

    if (!is_error(ret))
        return;
    static thread_local std::unordered_map<uint32_t, bool> is_network_call;
    auto known = is_network_call.find(nid);
    if (known == is_network_call.end()) {
        const char *n = import_name(nid);
        known = is_network_call.emplace(nid, n && (std::string_view(n).starts_with("sceNet") || std::string_view(n).starts_with("sceNp"))).first;
    }
    if (!known->second)
        return;
    const char *name = import_name(nid);
    {
        const std::lock_guard lock(mutex);
        if (errors_logged[{ nid, ret }]++ >= 5)
            return;
    }
    LOG_INFO("Call trace: {} on {} at {} returned 0x{:08X} (args {:08X} {:08X} {:08X} {:08X})", name, thread_name(emuenv, thread_id), log_hex(lr), ret,
        args[0], args[1], args[2], args[3]);
}
} // namespace call_trace

void call_import(EmuEnvState &emuenv, CPUState &cpu, uint32_t nid, SceUID thread_id) {
    // For crash reports: what each thread called last
    if (!recent_imports::namer)
        recent_imports::namer = import_name;
    recent_imports::record(thread_id, nid, read_lr(cpu));
#if defined(VITA3K_PLATFORM_IOS)
    // Heat: every 256 system calls, a game thread checks whether it should step down (util/thermal.h)
    {
        static thread_local uint32_t calls = 0;
        static thread_local int thermal_qos = 0;
        if ((++calls & 255) == 0) {
            const ThreadStatePtr self = emuenv.kernel.get_thread(thread_id);
            if (self)
                thermal::follow_game_qos(thermal_qos, self->get_priority() > SCE_KERNEL_GAME_DEFAULT_PRIORITY_ACTUAL);
        }
    }
#endif
    // HLE - call our C++ function
    if (emuenv.kernel.debugger.watch_import_calls) {
        const std::unordered_set<uint32_t> hle_nid_blacklist = {
            0xB295EB61, // sceKernelGetTLSAddr
            0x46E7BE7B, // sceKernelLockLwMutex
            0x91FA6614, // sceKernelUnlockLwMutex
        };
        auto lr = read_lr(cpu);
        log_import_call('H', nid, thread_id, hle_nid_blacklist, lr);
    }
    const ImportFn *fn = resolve_import(nid);
    if (write_watch::active())
        check_watch(emuenv, nid, thread_id, "before");
    if (fn) {
        const uint32_t args[4] = { read_reg(cpu, 0), read_reg(cpu, 1), read_reg(cpu, 2), read_reg(cpu, 3) };
        const Address lr = read_lr(cpu);
        (*fn)(emuenv, cpu, thread_id);
        if (write_watch::active())
            check_watch(emuenv, nid, thread_id, "inside");
        call_trace::record(emuenv, nid, thread_id, lr, args, read_reg(cpu, 0));
    } else {
        const ThreadStatePtr thread = emuenv.kernel.get_thread(thread_id);
        // make the function return 0
        write_reg(*thread->cpu, 0, 0);

        if (!emuenv.missing_nids.contains(nid) || LOG_UNK_NIDS_ALWAYS) {
            LOG_ERROR("Import function for NID {} not found (thread name: {}, thread ID: {})", log_hex(nid), thread->name, thread_id);
            if (!LOG_UNK_NIDS_ALWAYS)
                emuenv.missing_nids.insert(nid);
        }
    }
}

struct SceKernelBootimageModules {
    Ptr<const char> path;
    Ptr<const void> data;
    SceSize size;
};

struct SceKernelBootimageInfo {
    SceSize number;
    Ptr<const SceKernelBootimageModules> list;
};

constexpr uint32_t nid_sceKernelBootimageInfo = 0x9C08E88A;

SceUID load_module(EmuEnvState &emuenv, const std::string &module_path) {
    // Check if module is already loaded
    {
        const std::lock_guard<std::mutex> lock(emuenv.kernel.mutex);
        const auto &loaded_modules = emuenv.kernel.loaded_modules;
        auto module_iter = std::ranges::find_if(loaded_modules, [&](const auto &p) {
            return module_path == p.second->info.path;
        });

        if (module_iter != loaded_modules.end()) {
            return module_iter->first;
        }
    }

    LOG_INFO("Loading module \"{}\"", module_path);
    // Vitamin dumps carry Vitamin's own loader (steroid.suprx), which patches the system so a dumped game
    // can run as homebrew on a real Vita. Vita3K runs the decrypted game directly and doesn't need it (its
    // patches would only get in the way), so it is answered with an empty module like an HLE one.
    const bool vitamin_loader = string_utils::tolower(module_path).ends_with("sce_module/steroid.suprx");
    if (vitamin_loader)
        LOG_WARN("Vitamin dump: not loading Vitamin's steroid.suprx (the game runs without it)");
    if (vitamin_loader || module_path.starts_with("vs0:sys/external/")) {
        // check if module is LLEd or not
        // check only for this path because app modules are always LLEd and os0 modules can be loaded only by developer.
        const auto module_name = fs::path(module_path).stem().string();
        if (vitamin_loader || !is_lle_module(module_name, emuenv)) {
            LOG_INFO("Module {} is HLE. Skipping load.", module_name);
            const SceKernelModulePtr kernelModuleInfo = std::make_shared<KernelModule>();
            memset(kernelModuleInfo.get(), 0, sizeof(KernelModule));

            auto *sceKernelModuleInfo = &kernelModuleInfo->info;
            sceKernelModuleInfo->size = sizeof(*sceKernelModuleInfo);
            strncpy(sceKernelModuleInfo->path, module_path.c_str(), sizeof(sceKernelModuleInfo->path) - 1);
            // module_name is stubbed.
            strncpy(sceKernelModuleInfo->module_name, module_name.c_str(), 28);

            const SceUID uid = emuenv.kernel.get_next_uid();
            sceKernelModuleInfo->modid = uid;
            {
                const std::lock_guard<std::mutex> lock(emuenv.kernel.mutex);
                emuenv.kernel.loaded_modules[uid] = kernelModuleInfo;
            }
            return uid;
        }
    }

    const auto load_module_data = [&](const void *module_data) -> SceUID {
        SceUID module_id = load_self(emuenv.kernel, emuenv.mem, module_data, module_path, emuenv.log_path / "elfdumps" / emuenv.io.title_id);

        if (module_id >= 0) {
            const auto module = lock_and_find(module_id, emuenv.kernel.loaded_modules, emuenv.kernel.mutex);
            LOG_INFO("Module {} (at \"{}\") loaded", module->info.module_name, module_path);
            patch_adhoc_matching(emuenv.mem, module->info);
        } else {
            LOG_ERROR("Failed to load module {}", module_path);
        }

        return module_id;
    };

    VitaIoDevice device = device::get_device(module_path);
    auto device_for_icase = device;
    fs::path translated_module_path = translate_path(module_path.c_str(), device, emuenv.io.device_paths);
    auto system_path = device::construct_emulated_path(device, translated_module_path, emuenv.vita_fs_path, emuenv.io.redirect_stdio);

    if (module_path.starts_with("os0:kd/")) {
        if (!fs::exists(system_path)) {
            SceKernelBootimageInfo *bootimage_info = Ptr<SceKernelBootimageInfo>(emuenv.kernel.export_nids[nid_sceKernelBootimageInfo]).get(emuenv.mem);
            if (bootimage_info) {
                for (SceSize i = 0; i < bootimage_info->number; i++) {
                    const SceKernelBootimageModules &module_content = bootimage_info->list.get(emuenv.mem)[i];
                    if (module_content.path && module_content.data && module_content.size > 0) {
                        if (module_content.path.get(emuenv.mem) == module_path) {
                            // Load the module from the boot image
                            return load_module_data(module_content.data.get(emuenv.mem));
                        }
                    }
                }
            }
        }
    }

    if (emuenv.io.case_isens_find_enabled && !fs::exists(system_path)) {
        // Attempt a case-insensitive file search.
        const auto original_translated_module_path = translated_module_path;
        const auto cached_path = find_in_cache(emuenv.io, string_utils::tolower(translated_module_path.string()));
        if (!cached_path.empty()) {
            translated_module_path = cached_path;
            LOG_TRACE("Found cached filepath at {}", translated_module_path);
        } else {
            const bool path_found = find_case_isens_path(emuenv.io, device_for_icase, translated_module_path, system_path);
            translated_module_path = find_in_cache(emuenv.io, string_utils::tolower(system_path.string()));
            if (!translated_module_path.empty() && path_found) {
                LOG_TRACE("Found file on case-sensitive filesystem at {}", translated_module_path);
                translated_module_path = translated_module_path.string().substr(emuenv.vita_fs_path.string().length());
                translated_module_path = translated_module_path.string().substr(translated_module_path.string().find('/') + 1);
            } else {
                LOG_ERROR("Missing file at {} (target path: {})", original_translated_module_path.string(), module_path);
                return SCE_ERROR_ERRNO_ENOENT;
            }
        }
    }

    vfs::FileBuffer module_buffer;
    bool res;
    if (device == VitaIoDevice::app0)
        res = vfs::read_app_file(module_buffer, emuenv.vita_fs_path, emuenv.io.app_path, translated_module_path);
    else
        res = vfs::read_file(device, module_buffer, emuenv.vita_fs_path, translated_module_path);
    if (!res) {
        LOG_ERROR("Failed to read module file {}", module_path);
        return SCE_ERROR_ERRNO_ENOENT;
    }

    // Decrypt module file if necessary
    module_buffer = decrypt_fself(module_buffer, emuenv.license.rif[emuenv.io.title_id].key);
    if (module_buffer.empty()) {
        LOG_ERROR("Failed to decrypt module file {}", module_path);
        return SCE_ERROR_ERRNO_ENOENT;
    }

    return load_module_data(module_buffer.data());
}

int unload_module(EmuEnvState &emuenv, SceUID module_id) {
    const auto module = lock_and_find(module_id, emuenv.kernel.loaded_modules, emuenv.kernel.mutex);
    if (!module) {
        const char *export_name = __FUNCTION__;
        return RET_ERROR(SCE_KERNEL_ERROR_MODULEMGR_NO_MOD);
    }
    LOG_INFO("Unloading module {} ({})", module_id, module->info.module_name);
    if (module->info.segments[0].memsz == 0) {
        LOG_WARN("Module {} has no segments, skipping unload", module->info.module_name);
        {
            const std::lock_guard<std::mutex> lock(emuenv.kernel.mutex);
            emuenv.kernel.loaded_modules.erase(module->info.modid);
        }
        return 0;
    }
    return unload_self(emuenv.kernel, emuenv.mem, *module);
}

uint32_t start_module(EmuEnvState &emuenv, const SceKernelModuleInfo &module, SceSize args, Ptr<const void> argp) {
    const auto module_start = module.start_entry;
    if (module_start) {
        const auto module_name = module.module_name;

        LOG_DEBUG("Running module_start of library: {} at address {}", module_name, log_hex(module_start.address()));
        SceInt32 priority = SCE_KERNEL_DEFAULT_PRIORITY_USER;
        SceInt32 stack_size = SCE_KERNEL_STACK_SIZE_USER_MAIN;
        SceInt32 affinity = SCE_KERNEL_THREAD_CPU_AFFINITY_MASK_DEFAULT;
        // module_start is always called from new thread
        const ThreadStatePtr module_thread = emuenv.kernel.create_thread(emuenv.mem, module_name, module_start, priority, affinity, stack_size, 0);

        const uint32_t ret = module_thread->run_guest_function(args, argp.cast<void>());
        module_thread->remove();

        LOG_INFO("Module {} (at \"{}\") module_start returned {}", module_name, module.path, log_hex(ret));
        if (ret != SCE_KERNEL_START_SUCCESS)
            LOG_ERROR("Module {} did not return successfully!", module_name);

        return ret;
    }
    return 0;
}

uint32_t stop_module(EmuEnvState &emuenv, const SceKernelModuleInfo &module, SceSize args, Ptr<const void> argp) {
    const auto module_stop = module.stop_entry;
    if (module_stop) {
        const auto module_name = module.module_name;

        LOG_DEBUG("Running module_stop of library: {} at address {}", module_name, log_hex(module_stop.address()));
        SceInt32 priority = SCE_KERNEL_DEFAULT_PRIORITY_USER;
        SceInt32 stack_size = SCE_KERNEL_STACK_SIZE_USER_MAIN;
        SceInt32 affinity = SCE_KERNEL_THREAD_CPU_AFFINITY_MASK_DEFAULT;
        // module_stop is always called from new thread
        const ThreadStatePtr module_thread = emuenv.kernel.create_thread(emuenv.mem, module_name, module_stop, priority, affinity, stack_size, 0);

        const uint32_t ret = module_thread->run_guest_function(args, argp.cast<void>());
        module_thread->remove();

        LOG_INFO("Module {} (at \"{}\") module_stop returned {}", module_name, module.path, log_hex(ret));
        if (ret != SCE_KERNEL_STOP_SUCCESS)
            LOG_ERROR("Module {} did not stop successfully!", module_name);
        return ret;
    }
    return 0;
}

/**
 * \return False on failure, true on success
 */
bool load_sys_module(EmuEnvState &emuenv, SceSysmoduleModuleId module_id) {
    const auto &module_paths = sysmodule_paths[module_id];
    std::vector<SceUID> loaded_uids;
    for (const auto module_filename : module_paths) {
        std::string module_path;
        if (module_id == SCE_SYSMODULE_SMART || module_id == SCE_SYSMODULE_FACE || (module_id == SCE_SYSMODULE_ULT && strcmp(module_filename, "libult") == 0)) {
            module_path = fmt::format("app0:sce_module/{}.suprx", module_filename);
        } else {
            module_path = fmt::format("vs0:sys/external/{}.suprx", module_filename);
        }

        auto loaded_module_uid = load_module(emuenv, module_path);

        if (loaded_module_uid < 0) {
            if (module_id == SCE_SYSMODULE_ULT && loaded_module_uid == SCE_ERROR_ERRNO_ENOENT) {
                module_path = fmt::format("vs0:sys/external/{}.suprx", module_filename);
                loaded_module_uid = load_module(emuenv, module_path);
                if (loaded_module_uid < 0)
                    return false;
            } else
                return false;
        }
        loaded_uids.push_back(loaded_module_uid);
        const auto module = lock_and_find(loaded_module_uid, emuenv.kernel.loaded_modules, emuenv.kernel.mutex);
        start_module(emuenv, module->info);
    }

    std::lock_guard<std::mutex> guard(emuenv.kernel.mutex);
    emuenv.kernel.loaded_sysmodules[module_id] = std::move(loaded_uids);
    return true;
}

int unload_sys_module(EmuEnvState &emuenv, SceSysmoduleModuleId module_id) {
    const char *export_name = __FUNCTION__;

    std::vector<SceUID> loaded_uids;
    {
        std::lock_guard<std::mutex> guard(emuenv.kernel.mutex);
        auto it = emuenv.kernel.loaded_sysmodules.find(module_id);
        if (it == emuenv.kernel.loaded_sysmodules.end())
            return RET_ERROR(SCE_SYSMODULE_ERROR_UNLOADED);
        loaded_uids = std::move(it->second);
        emuenv.kernel.loaded_sysmodules.erase(it);
    }

    // unload the modules in the reverse order they were loaded
    std::ranges::reverse(loaded_uids);

    // first stop everything, then unload
    for (SceUID uid : loaded_uids) {
        const auto module = lock_and_find(uid, emuenv.kernel.loaded_modules, emuenv.kernel.mutex);
        if (!module)
            return RET_ERROR(SCE_SYSMODULE_ERROR_FATAL);

        stop_module(emuenv, module->info);
    }
    for (SceUID uid : loaded_uids) {
        int ret = unload_module(emuenv, uid);
        if (ret < 0)
            return RET_ERROR(SCE_SYSMODULE_ERROR_FATAL);
    }

    return 0;
}

bool load_sys_module_internal_with_arg(EmuEnvState &emuenv, SceSysmoduleInternalModuleId module_id, SceSize args, Ptr<void> argp, int *retcode) {
    LOG_INFO("Loading internal module ID: {}", log_hex(module_id));

    if (!sysmodule_internal_paths.contains(module_id))
        return false;

    const auto &module_paths = sysmodule_internal_paths.at(module_id);

    for (auto module_filename : module_paths) {
        std::string module_path = fmt::format("vs0:sys/external/{}.suprx", module_filename);
        auto loaded_module_uid = load_module(emuenv, module_path);

        if (loaded_module_uid < 0) {
            return false;
        }
        const auto module = lock_and_find(loaded_module_uid, emuenv.kernel.loaded_modules, emuenv.kernel.mutex);
        auto ret = start_module(emuenv, module->info, args, argp);
        if (retcode)
            *retcode = static_cast<int>(ret);
    }
    emuenv.kernel.loaded_internal_sysmodules.push_back(module_id);
    return true;
}

void init_libraries(EmuEnvState &emuenv) {
#define LIBRARY(name) import_library_init_##name(emuenv);
#include <modules/library_init_list.inc>
#undef LIBRARY
}
