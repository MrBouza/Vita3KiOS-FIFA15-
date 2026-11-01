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

#include "ios_jit.h"

#include <libkern/OSCacheControl.h>
#include <mach/mach.h>
#include <sys/mman.h>
#include <sys/sysctl.h>
#include <sys/ucontext.h>
#include <unistd.h>

#include <atomic>
#include <chrono>
#include <csetjmp>
#include <csignal>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iterator>
#include <map>
#include <mutex>
#include <thread>

extern "C" int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);

// ---- StikDebug universal.js protocol: brk #0xf00d, command in x16, arguments in x0/x1 ----
// x16 = 1: prepare region. x0 = address (NULL: let the debugger allocate it), x1 = length.
//          Returns the executable address in x0.
// x16 = 0: detach.

extern "C" __attribute__((naked, noinline)) void *v3k_jit26_prepare_region(void *address, size_t length) {
    __asm__(
        "mov x16, #1\n"
        "brk #0xf00d\n"
        "ret\n");
}

extern "C" __attribute__((naked, noinline)) void v3k_jit26_detach() {
    __asm__(
        "mov x16, #0\n"
        "brk #0xf00d\n"
        "ret\n");
}

namespace ios {

namespace {

constexpr std::size_t page_size = 16 * 1024;
// Executable memory the debugger prepares. It writes one byte per page over the debug connection
// while the app is stopped, so this stays modest: 64 MiB = 4096 pages, 32 code caches of 2 MiB.
constexpr std::size_t txm_arena_size = 64 * 1024 * 1024;
// Without TXM the arena only reserves address space, so it can be larger
constexpr std::size_t legacy_arena_size = 512 * 1024 * 1024;
constexpr uint32_t brk_f00d = 0xD43E01A0; // brk #0xf00d

JitStatus status;
std::mutex status_mutex;
std::atomic<bool> preparing{ false };
std::once_flag init_flag;
std::function<void(const std::string &)> log_fn;

void log(const std::string &message) {
    if (log_fn)
        log_fn("JIT: " + message);
}

void set_status(JitMode mode, std::size_t arena_size, std::string detail) {
    log(detail);
    std::lock_guard lock(status_mutex);
    status.mode = mode;
    status.arena_size = arena_size;
    status.detail = std::move(detail);
}

// ---- Arena: one executable region + writable alias, handed out first-fit ----
struct Arena {
    uint8_t *exec = nullptr;
    uint8_t *write = nullptr;
    std::size_t size = 0;
    std::map<std::size_t, std::size_t> free_ranges; // offset -> length
    std::mutex mutex;
} arena;

std::size_t round_up(std::size_t value) {
    return (value + page_size - 1) & ~(page_size - 1);
}

bool is_debugged() {
    constexpr unsigned int CS_OPS_STATUS = 0;
    constexpr uint32_t CS_DEBUGGED = 0x10000000;
    uint32_t flags = 0;
    if (csops(getpid(), CS_OPS_STATUS, &flags, sizeof(flags)) != 0)
        return false;
    return (flags & CS_DEBUGGED) != 0;
}

// True while a debugger is attached right now (CS_DEBUGGED stays set after it detaches)
bool is_traced() {
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid() };
    struct kinfo_proc info {};
    size_t size = sizeof(info);
    if (sysctl(mib, 4, &info, &size, nullptr, 0) != 0)
        return false;
    return (info.kp_proc.p_flag & P_TRACED) != 0;
}

int os_major_version() {
    char version[32] = {};
    size_t size = sizeof(version);
    if (sysctlbyname("kern.osproductversion", version, &size, nullptr, 0) != 0)
        return 0;
    return std::atoi(version);
}

// ---- Signal guards ----
// A brk that no debugger services raises SIGTRAP: skip it and report failure instead of dying.
// A jump into memory that is not executable raises SIGBUS/SIGSEGV: catch it during the self-test.
volatile sig_atomic_t trap_skipped = 0;
volatile sig_atomic_t self_testing = 0;
sigjmp_buf self_test_jump;

void trap_handler(int, siginfo_t *, void *context) {
    auto *uc = static_cast<ucontext_t *>(context);
    auto &state = uc->uc_mcontext->__ss;
    if (*reinterpret_cast<const uint32_t *>(state.__pc) == brk_f00d) {
        state.__x[0] = 0;
        state.__pc += 4;
        trap_skipped = 1;
        return;
    }
    signal(SIGTRAP, SIG_DFL);
    raise(SIGTRAP);
}

void fault_handler(int sig, siginfo_t *, void *) {
    if (self_testing)
        siglongjmp(self_test_jump, 1);
    signal(sig, SIG_DFL);
    raise(sig);
}

struct ScopedSignal {
    int sig;
    struct sigaction old {};
    ScopedSignal(int sig, void (*handler)(int, siginfo_t *, void *))
        : sig(sig) {
        struct sigaction action {};
        action.sa_sigaction = handler;
        action.sa_flags = SA_SIGINFO;
        sigemptyset(&action.sa_mask);
        sigaction(sig, &action, &old);
    }
    ~ScopedSignal() {
        sigaction(sig, &old, nullptr);
    }
};

// Writes `mov w0, #42; ret` through the writable view and runs it from the executable view
bool self_test(uint8_t *exec, uint8_t *write) {
    auto *code = reinterpret_cast<uint32_t *>(write);
    code[0] = 0x52800540; // mov w0, #42
    code[1] = 0xD65F03C0; // ret
    sys_icache_invalidate(exec, 8);

    ScopedSignal bus(SIGBUS, fault_handler);
    ScopedSignal segv(SIGSEGV, fault_handler);
    int result = -1;
    self_testing = 1;
    if (sigsetjmp(self_test_jump, 1) == 0)
        result = reinterpret_cast<int (*)()>(exec)();
    self_testing = 0;

    code[0] = 0;
    code[1] = 0;
    sys_icache_invalidate(exec, 8);
    return result == 42;
}

bool region_is_executable(uint8_t *address, std::size_t size) {
    vm_address_t region = reinterpret_cast<vm_address_t>(address);
    vm_size_t region_size = 0;
    vm_region_basic_info_data_64_t info{};
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object = MACH_PORT_NULL;
    if (vm_region_64(mach_task_self(), &region, &region_size, VM_REGION_BASIC_INFO_64,
            reinterpret_cast<vm_region_info_t>(&info), &count, &object)
        != KERN_SUCCESS)
        return false;
    const auto begin = reinterpret_cast<uintptr_t>(address);
    return region <= begin && region + region_size >= begin + size && (info.protection & VM_PROT_EXECUTE);
}

// Maps a read/write alias of [exec, exec + size)
uint8_t *make_writable_alias(uint8_t *exec, std::size_t size, std::string &error) {
    vm_address_t alias = 0;
    vm_prot_t cur = VM_PROT_NONE, max = VM_PROT_NONE;
    kern_return_t kr = vm_remap(mach_task_self(), &alias, size, 0, VM_FLAGS_ANYWHERE, mach_task_self(),
        reinterpret_cast<vm_address_t>(exec), false, &cur, &max, VM_INHERIT_NONE);
    if (kr != KERN_SUCCESS) {
        error = "vm_remap failed (" + std::to_string(kr) + ")";
        return nullptr;
    }
    kr = vm_protect(mach_task_self(), alias, size, false, VM_PROT_READ | VM_PROT_WRITE);
    if (kr != KERN_SUCCESS) {
        vm_deallocate(mach_task_self(), alias, size);
        error = "vm_protect RW failed (" + std::to_string(kr) + ")";
        return nullptr;
    }
    return reinterpret_cast<uint8_t *>(alias);
}

void adopt_arena(uint8_t *exec, uint8_t *write, std::size_t size) {
    std::lock_guard lock(arena.mutex);
    arena.exec = exec;
    arena.write = write;
    arena.size = size;
    arena.free_ranges = { { 0, size } };
}

// iOS 26 TXM: ask the debugger script for an executable region
bool try_txm(std::string &detail) {
    uint8_t *exec = nullptr;
    {
        ScopedSignal trap(SIGTRAP, trap_handler);
        for (int attempt = 0; attempt < 3 && !exec; attempt++) {
            trap_skipped = 0;
            auto *result = static_cast<uint8_t *>(v3k_jit26_prepare_region(nullptr, txm_arena_size));
            if (trap_skipped) {
                detail = "No JIT script answered. Select universal.js as the JIT script for Vita3K.";
                return false;
            }
            // An unserviced or failed request can leave junk in x0, so validate the region itself
            if (result && (reinterpret_cast<uintptr_t>(result) % page_size) == 0 && region_is_executable(result, txm_arena_size))
                exec = result;
            else
                std::this_thread::sleep_for(std::chrono::milliseconds(150));
        }
    }
    if (!exec) {
        detail = "The JIT script did not return executable memory.";
        return false;
    }

    log("executable memory received, mapping the writable view");
    std::string error;
    uint8_t *write = make_writable_alias(exec, txm_arena_size, error);

    {
        // All regions are prepared: let the debugger go (the memory stays executable)
        log("detaching the JIT script");
        ScopedSignal trap(SIGTRAP, trap_handler);
        v3k_jit26_detach();
    }
    log("running the JIT self-test");

    if (!write) {
        detail = "Could not create the writable JIT view: " + error;
        return false;
    }
    if (!self_test(exec, write)) {
        detail = "The prepared JIT memory failed its self-test.";
        return false;
    }
    adopt_arena(exec, write, txm_arena_size);
    return true;
}

// Classic path (iOS 17.4-18, or devices without TXM): RW memory plus an executable alias
bool try_legacy(std::string &detail) {
    log("trying the classic dual mapping");
    void *rw = mmap(nullptr, legacy_arena_size, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    if (rw == MAP_FAILED) {
        detail = "Could not reserve JIT memory.";
        return false;
    }
    vm_address_t alias = 0;
    vm_prot_t cur = VM_PROT_NONE, max = VM_PROT_NONE;
    kern_return_t kr = vm_remap(mach_task_self(), &alias, legacy_arena_size, 0, VM_FLAGS_ANYWHERE, mach_task_self(),
        reinterpret_cast<vm_address_t>(rw), false, &cur, &max, VM_INHERIT_NONE);
    if (kr != KERN_SUCCESS || mprotect(reinterpret_cast<void *>(alias), legacy_arena_size, PROT_READ | PROT_EXEC) != 0) {
        if (kr == KERN_SUCCESS)
            vm_deallocate(mach_task_self(), alias, legacy_arena_size);
        munmap(rw, legacy_arena_size);
        detail = "Could not map executable JIT memory.";
        return false;
    }
    auto *exec = reinterpret_cast<uint8_t *>(alias);
    auto *write = static_cast<uint8_t *>(rw);
    if (!self_test(exec, write)) {
        vm_deallocate(mach_task_self(), alias, legacy_arena_size);
        munmap(rw, legacy_arena_size);
        detail = "Executable memory is blocked.";
        return false;
    }
    adopt_arena(exec, write, legacy_arena_size);
    return true;
}

void initialize() {
    log("checking for a debugger");
    for (int i = 0; i < 30 && !is_debugged(); i++)
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
    if (!is_debugged()) {
        set_status(JitMode::None, 0, "JIT is not enabled. Launch Vita3K from StikDebug, or with \"Launch with JIT\" in LiveContainer.");
        return;
    }

    const int os_major = os_major_version();
    log("debugger flag set, iOS " + std::to_string(os_major) + ", debugger attached now: " + (is_traced() ? "yes" : "no"));

    std::string txm_detail;
    if (os_major >= 26) {
        // A JIT script stays attached waiting for our request; a plain enabler attaches and leaves.
        // Only send the request while something is attached to answer it, otherwise the app could
        // stop on a breakpoint nobody handles.
        bool attached = is_traced();
        for (int i = 0; i < 15 && attached; i++) {
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
            attached = is_traced();
        }
        if (attached) {
            log("requesting " + std::to_string(txm_arena_size / (1024 * 1024)) + " MiB of executable memory from the JIT script");
            if (try_txm(txm_detail)) {
                set_status(JitMode::Txm, txm_arena_size, "JIT ready (iOS 26 script).");
                return;
            }
            log(txm_detail);
        } else {
            txm_detail = "No JIT script is attached.";
            log("debugger already detached, no JIT script to ask");
        }
    }

    std::string legacy_detail;
    if (try_legacy(legacy_detail)) {
        set_status(JitMode::Legacy, legacy_arena_size, "JIT ready.");
        return;
    }
    log(legacy_detail);

    set_status(JitMode::None, 0,
        os_major >= 26
            ? txm_detail + " On iOS 26 with an A15 or newer chip, choose StikDebug's universal.js as Vita3K's JIT script (LiveContainer: long-press Vita3K > Settings > JIT Launch Script), keep Launch with JIT on, then reopen Vita3K."

            : legacy_detail + " Relaunch Vita3K with JIT enabled.");
}

} // namespace

void jit_set_logger(std::function<void(const std::string &)> logger) {
    log_fn = std::move(logger);
}

void jit_init_async() {
    std::call_once(init_flag, [] {
        preparing = true;
        std::thread([] {
            initialize();
            preparing = false;
        }).detach();
    });
}

bool jit_preparing() {
    return preparing;
}

JitStatus jit_status() {
    std::lock_guard lock(status_mutex);
    return status;
}

bool jit_ready() {
    std::lock_guard lock(status_mutex);
    return status.mode != JitMode::None;
}

} // namespace ios

// ---- Allocator used by oaknut::CodeBlock (patches/dynarmic-ios-jit.patch) ----

extern "C" void *oaknut_ios_jit_alloc(std::size_t size, void **writable) {
    using namespace ios;
    *writable = nullptr;
    const std::size_t length = round_up(size);
    std::lock_guard lock(arena.mutex);
    for (auto it = arena.free_ranges.begin(); it != arena.free_ranges.end(); ++it) {
        if (it->second < length)
            continue;
        const std::size_t offset = it->first;
        const std::size_t remaining = it->second - length;
        arena.free_ranges.erase(it);
        if (remaining)
            arena.free_ranges.emplace(offset + length, remaining);
        *writable = arena.write + offset;
        return arena.exec + offset;
    }
    std::fprintf(stderr, "Vita3K: JIT arena exhausted or unavailable (requested %zu bytes)\n", size);
    return nullptr;
}

extern "C" void oaknut_ios_jit_free(void *executable, std::size_t size) {
    using namespace ios;
    if (!executable)
        return;
    std::lock_guard lock(arena.mutex);
    const std::size_t offset = static_cast<uint8_t *>(executable) - arena.exec;
    std::size_t length = round_up(size);
    std::size_t start = offset;
    // Merge with the neighbouring free ranges
    auto next = arena.free_ranges.lower_bound(offset);
    if (next != arena.free_ranges.end() && next->first == offset + length) {
        length += next->second;
        next = arena.free_ranges.erase(next);
    }
    if (next != arena.free_ranges.begin()) {
        auto prev = std::prev(next);
        if (prev->first + prev->second == start) {
            start = prev->first;
            length += prev->second;
            arena.free_ranges.erase(prev);
        }
    }
    arena.free_ranges.emplace(start, length);
}
