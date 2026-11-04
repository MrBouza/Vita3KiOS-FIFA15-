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

#include "cpu/common.h"
#include <cpu/impl/dynarmic_cpu.h>
#include <cpu/state.h>
#include <util/log.h>

#include <mem/ptr.h>

#include <dynarmic/frontend/A32/a32_ir_emitter.h>
#include <dynarmic/interface/A32/coprocessor.h>
#include <dynarmic/interface/exclusive_monitor.h>

// iOS JIT region pool, from Tsubomi by 125hz (https://github.com/125hz/Tsubomi).
// oaknut is dynarmic's arm64 assembler; its pool only exists on arm64 devices.
#if defined(VITA3K_PLATFORM_IOS) && defined(__aarch64__)
#include <oaknut/code_block.hpp>
#include <spdlog/spdlog.h>

#include <chrono>
#include <mach/mach.h>
#include <sys/mman.h>
#endif

#include <atomic>
#include <bit>
#include <memory>
#include <mutex>
#include <optional>
#include <string>

#if defined(VITA3K_PLATFORM_IOS) && defined(__aarch64__)
namespace {

std::atomic<std::size_t> ios_jit_regions_prepared{ 0 };

void log_ios_jit_region_pool_event(oaknut::JitRegionPoolEvent event, std::size_t size, std::size_t available) {
    switch (event) {
    case oaknut::JitRegionPoolEvent::Take:
        LOG_INFO("iOS JIT region pool take: size={} bytes available={}", size, available);
        break;
    case oaknut::JitRegionPoolEvent::Return:
        LOG_INFO("iOS JIT region pool return: size={} bytes available={}", size, available);
        break;
    case oaknut::JitRegionPoolEvent::Miss:
        LOG_INFO("iOS JIT region pool miss: size={} bytes available={}", size, available);
        break;
    case oaknut::JitRegionPoolEvent::Prewarm:
        ios_jit_regions_prepared = available;
        LOG_INFO("iOS JIT region pool prewarm: size={} bytes available={}", size, available);
        break;
    case oaknut::JitRegionPoolEvent::SessionLost:
        LOG_CRITICAL("StikDebug JIT session lost - cannot prepare a new JIT region; reopen StikDebug and re-enable JIT");
        if (auto logger = spdlog::default_logger())
            logger->flush();
        break;
    }
}

} // namespace

// Prepares every missing region with a single request to the JIT script: one large RX mapping,
// one writable alias, then cut into cache_size pieces for the pool. StikDebug pauses the app for each
// request, so 32 separate requests froze the app for ~3.5 s at launch. Returns false (and leaves the
// pool untouched) if the script refuses the large request, so the one-by-one path can take over.
static bool prewarm_ios_jit_pool_in_one_request(std::size_t target_count, std::size_t cache_size) {
    using namespace oaknut::detail;
    const std::size_t have = matching_region_count(cache_size);
    if (have >= target_count || !is_process_traced())
        return have >= target_count;
    const std::size_t count = target_count - have;
    const std::size_t total = count * cache_size;

    const auto started = std::chrono::steady_clock::now();
    void *mapping = mmap(nullptr, total, PROT_READ | PROT_EXEC, MAP_ANON | MAP_PRIVATE, -1, 0);
    if (mapping == MAP_FAILED)
        return false;
    auto *rx = static_cast<std::uint32_t *>(prepare_universal_jit_region(mapping, total));
    if (!rx) {
        munmap(mapping, total);
        LOG_WARN("iOS JIT: the script did not prepare a {} MiB region in one request, preparing regions one by one", total / (1024 * 1024));
        return false;
    }
    vm_prot_t current_protection = 0, maximum_protection = 0;
    vm_address_t writable = 0;
    if (vm_remap(mach_task_self(), &writable, total, 0, VM_FLAGS_ANYWHERE | VM_FLAGS_RANDOM_ADDR, mach_task_self(),
            reinterpret_cast<vm_address_t>(rx), false, &current_protection, &maximum_protection, VM_INHERIT_NONE)
            != KERN_SUCCESS
        || vm_protect(mach_task_self(), writable, total, false, VM_PROT_READ | VM_PROT_WRITE) != KERN_SUCCESS) {
        LOG_WARN("iOS JIT: could not map the batched region writable, preparing regions one by one");
        return false;
    }
    auto *rw = reinterpret_cast<std::uint32_t *>(writable);
    const std::size_t words = cache_size / sizeof(std::uint32_t);
    auto &pool = jit_region_pool();
    for (std::size_t i = 0; i < count; i++) {
        std::size_t available;
        {
            const std::lock_guard lock(pool.mutex);
            pool.regions.push_back(PreparedJitRegion{ rx + i * words, rw + i * words, cache_size });
            available = have + i + 1;
        }
        log_ios_jit_region_pool_event(oaknut::JitRegionPoolEvent::Prewarm, cache_size, available);
    }
    const auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - started).count();
    LOG_INFO("iOS JIT: prepared {} regions ({} MiB) in one request, {} ms", count, total / (1024 * 1024), ms);
    return true;
}

std::size_t prewarm_ios_jit_code_cache_pool(std::size_t target_count, std::size_t cache_size) {
    oaknut::set_jit_region_pool_log_callback(&log_ios_jit_region_pool_event);
    LOG_INFO("iOS JIT region pool prewarm starting: target={} size={} bytes ({} MiB each)",
        target_count, cache_size, cache_size / (1024 * 1024));
    prewarm_ios_jit_pool_in_one_request(target_count, cache_size);
    // Anything still missing (or everything, if the batched request was refused) one region at a time
    const std::size_t available = oaknut::prewarm_jit_region_pool(cache_size, target_count);
    LOG_INFO("iOS JIT region pool prewarm complete: target={} available={} size={} bytes",
        target_count, available, cache_size);
    return available;
}

std::size_t ios_jit_code_cache_pool_progress() {
    return ios_jit_regions_prepared;
}

std::size_t ios_jit_code_cache_pool_available(std::size_t cache_size) {
    return oaknut::detail::matching_region_count(cache_size);
}
#endif

class ArmDynarmicCP15 : public Dynarmic::A32::Coprocessor {
public:
    using CoprocReg = Dynarmic::A32::CoprocReg;

    uint32_t tpidruro = 0;
    uint32_t tpidrurw = 0;
    uint32_t sctlr = 0;
    uint32_t dacr = 0;

    std::optional<Callback> CompileInternalOperation(bool two, unsigned opc1, CoprocReg CRd,
        CoprocReg CRn, CoprocReg CRm,
        unsigned opc2) override {
        return std::nullopt;
    }

    // MCR p15, 0, Rt, CRn, c0, opc2 for TPIDRURO (c13, 3), TPIDRURW (c13, 2), SCTLR (c1, 0) and DACR (c3, 0)
    CallbackOrAccessOneWord CompileSendOneWord(bool two, unsigned opc1, CoprocReg CRn,
        CoprocReg CRm, unsigned opc2) override {
        if (opc1 == 0 && CRm == CoprocReg::C0) {
            if (CRn == CoprocReg::C13 && opc2 == 3)
                return &tpidruro;
            if (!two && CRn == CoprocReg::C13 && opc2 == 2)
                return &tpidrurw;
            if (!two && CRn == CoprocReg::C1 && opc2 == 0)
                return &sctlr;
            if (!two && CRn == CoprocReg::C3 && opc2 == 0)
                return &dacr;
        }
        LOG_WARN("Unhandled CP15 MCR or MRC: two={} opc1={} CRn={} CRm={} opc2={}", two, opc1, static_cast<int>(CRn), static_cast<int>(CRm), opc2);
        return CallbackOrAccessOneWord{};
    }

    CallbackOrAccessTwoWords CompileSendTwoWords(bool two, unsigned opc, CoprocReg CRm) override {
        return CallbackOrAccessTwoWords{};
    }

    // MRC reads the same registers
    CallbackOrAccessOneWord CompileGetOneWord(bool two, unsigned opc1, CoprocReg CRn, CoprocReg CRm,
        unsigned opc2) override {
        return CompileSendOneWord(two, opc1, CRn, CRm, opc2);
    }

    CallbackOrAccessTwoWords CompileGetTwoWords(bool two, unsigned opc, CoprocReg CRm) override {
        return CallbackOrAccessTwoWords{};
    }

    std::optional<Callback> CompileLoadWords(bool two, bool long_transfer, CoprocReg CRd,
        std::optional<std::uint8_t> option) override {
        return std::nullopt;
    }

    std::optional<Callback> CompileStoreWords(bool two, bool long_transfer, CoprocReg CRd,
        std::optional<std::uint8_t> option) override {
        return std::nullopt;
    }
};

static constexpr bool LOG_INVALID_ACCESS = false;

class ArmDynarmicCallback : public Dynarmic::A32::UserCallbacks {
    CPUState *parent;
    DynarmicCPU *cpu;

public:
    explicit ArmDynarmicCallback(CPUState &parent, DynarmicCPU &cpu)
        : parent(&parent)
        , cpu(&cpu) {}

    std::optional<std::uint32_t> MemoryReadCode(Dynarmic::A32::VAddr addr) override {
        if (cpu->log_mem)
            LOG_TRACE("Instruction fetch at address 0x{:X}", addr);
        if (addr < KiB(4))
            return std::nullopt;
        return MemoryRead32(addr);
    }

    static void TraceInstruction(uint64_t self_, uint64_t address, uint64_t is_thumb) {
        ArmDynarmicCallback &self = *reinterpret_cast<ArmDynarmicCallback *>(self_);

        const bool valid = is_valid_addr(*self.parent->mem, static_cast<Address>(address));
        const std::string disassembly = valid ? disassemble(*self.parent, address) : "invalid address";
        LOG_TRACE("{} ({}): {} {}", log_hex(self_), self.parent->thread_id, log_hex(address), disassembly);
    }

    void PreCodeTranslationHook(bool is_thumb, Dynarmic::A32::VAddr pc, Dynarmic::A32::IREmitter &ir) override {
        if (cpu->log_code) {
            ir.CallHostFunction(&TraceInstruction, ir.Imm64(reinterpret_cast<uint64_t>(this)), ir.Imm64(pc), ir.Imm64(is_thumb));
        }
    }

    // Logs and returns true if guest code may not access addr
    bool invalid_access(const char *access, Dynarmic::A32::VAddr addr) {
        MemState &mem = *parent->mem;
        if (addr >= mem.host_page_size && is_valid_addr(mem, addr))
            return false;
        const uint32_t pc = cpu->get_pc();
        if (LOG_INVALID_ACCESS) {
            LOG_ERROR("Invalid {} at 0x{:x}\n{}", access, addr, cpu->save_context().description());
            if (pc < mem.host_page_size)
                LOG_CRITICAL("PC is 0x{:x}", pc);
            else
                LOG_ERROR("Executing: {}", disassemble(*parent, pc, nullptr));
        } else if (!mem.invalid_access_logged.test_and_set()) {
            LOG_ERROR("Invalid {} at 0x{:x} by thread {} (pc 0x{:x}). Set LOG_INVALID_ACCESS for full reports", access, addr, parent->thread_id, pc);
        } else {
            LOG_ERROR("Invalid {} at 0x{:x} by thread {} (pc 0x{:x})", access, addr, parent->thread_id, pc);
        }
        return true;
    }

    template <typename T>
    T MemoryRead(Dynarmic::A32::VAddr addr) {
        if (invalid_access("read", addr))
            return 0;
        const T ret = *Ptr<T>(addr).get(*parent->mem);
        if (cpu->log_mem) {
            LOG_TRACE("Read uint{}_t at address: 0x{:x}, val = 0x{:x}", sizeof(T) * 8, addr, ret);
        }
        return ret;
    }

    uint8_t MemoryRead8(Dynarmic::A32::VAddr addr) override {
        return MemoryRead<uint8_t>(addr);
    }

    uint16_t MemoryRead16(Dynarmic::A32::VAddr addr) override {
        return MemoryRead<uint16_t>(addr);
    }

    uint32_t MemoryRead32(Dynarmic::A32::VAddr addr) override {
        return MemoryRead<uint32_t>(addr);
    }

    uint64_t MemoryRead64(Dynarmic::A32::VAddr addr) override {
        return MemoryRead<uint64_t>(addr);
    }

    template <typename T>
    void MemoryWrite(Dynarmic::A32::VAddr addr, T value) {
        if (invalid_access("write", addr))
            return;
        *Ptr<T>(addr).get(*parent->mem) = value;
        if (cpu->log_mem) {
            LOG_TRACE("Write uint{}_t at addr: 0x{:x}, val = 0x{:x}", sizeof(T) * 8, addr, value);
        }
    }

    void MemoryWrite8(Dynarmic::A32::VAddr addr, uint8_t value) override {
        MemoryWrite<uint8_t>(addr, value);
    }

    void MemoryWrite16(Dynarmic::A32::VAddr addr, uint16_t value) override {
        MemoryWrite<uint16_t>(addr, value);
    }

    void MemoryWrite32(Dynarmic::A32::VAddr addr, uint32_t value) override {
        MemoryWrite<uint32_t>(addr, value);
    }

    void MemoryWrite64(Dynarmic::A32::VAddr addr, uint64_t value) override {
        MemoryWrite<uint64_t>(addr, value);
    }

    template <typename T>
    bool MemoryWriteExclusive(Dynarmic::A32::VAddr addr, T value, T expected) {
        if (invalid_access("exclusive write", addr))
            return false;
        const bool result = Ptr<T>(addr).atomic_compare_and_swap(*parent->mem, value, expected);
        if (cpu->log_mem) {
            LOG_TRACE("Write uint{}_t at addr: 0x{:x}, val = 0x{:x}, expected = 0x{:x}", sizeof(T) * 8, addr, value, expected);
        }
        return result;
    }

    bool MemoryWriteExclusive8(Dynarmic::A32::VAddr addr, uint8_t value, uint8_t expected) override {
        return MemoryWriteExclusive(addr, value, expected);
    }

    bool MemoryWriteExclusive16(Dynarmic::A32::VAddr addr, uint16_t value, uint16_t expected) override {
        return MemoryWriteExclusive(addr, value, expected);
    }

    bool MemoryWriteExclusive32(Dynarmic::A32::VAddr addr, uint32_t value, uint32_t expected) override {
        return MemoryWriteExclusive(addr, value, expected);
    }

    bool MemoryWriteExclusive64(Dynarmic::A32::VAddr addr, uint64_t value, uint64_t expected) override {
        return MemoryWriteExclusive(addr, value, expected);
    }

    void InterpreterFallback(Dynarmic::A32::VAddr addr, size_t num_insts) override {
        LOG_ERROR("Unimplemented instruction at address {}:\n{}", log_hex(addr), save_context(*parent).description());
    }

    void ExceptionRaised(uint32_t pc, Dynarmic::A32::Exception exception) override {
        switch (exception) {
        case Dynarmic::A32::Exception::Breakpoint:
            cpu->break_ = true;
            cpu->jit->HaltExecution();
            cpu->set_pc(cpu->is_thumb_mode() ? pc | 1 : pc);
            break;
        case Dynarmic::A32::Exception::NoExecuteFault:
            LOG_CRITICAL("PC is 0x{:x}, stopping thread {}\n{}", pc, parent->thread_id, cpu->save_context().description());
            [[fallthrough]];
        case Dynarmic::A32::Exception::WaitForInterrupt:
            cpu->halted = true;
            cpu->jit->HaltExecution();
            break;
        case Dynarmic::A32::Exception::PreloadDataWithIntentToWrite:
        case Dynarmic::A32::Exception::PreloadData:
        case Dynarmic::A32::Exception::PreloadInstruction:
        case Dynarmic::A32::Exception::SendEvent:
        case Dynarmic::A32::Exception::SendEventLocal:
        case Dynarmic::A32::Exception::WaitForEvent:
        case Dynarmic::A32::Exception::Yield:
            break;
        case Dynarmic::A32::Exception::UndefinedInstruction:
            LOG_WARN("Undefined instruction at address 0x{:X}, instruction 0x{:X} ({})", pc, MemoryReadCode(pc).value(), disassemble(*parent, pc, nullptr));
            InterpreterFallback(pc, 1);
            break;
        case Dynarmic::A32::Exception::UnpredictableInstruction:
            LOG_WARN("Unpredictable instruction at address 0x{:X}, instruction 0x{:X} ({})", pc, MemoryReadCode(pc).value(), disassemble(*parent, pc, nullptr));
            InterpreterFallback(pc, 1);
            break;
        case Dynarmic::A32::Exception::DecodeError:
            LOG_WARN("Decode error at address 0x{:X}, instruction 0x{:X} ({})", pc, MemoryReadCode(pc).value(), disassemble(*parent, pc, nullptr));
            InterpreterFallback(pc, 1);
            break;
        default:
            LOG_WARN("Unknown exception {} Raised at pc = 0x{:x}", static_cast<size_t>(exception), pc);
            LOG_TRACE("at address 0x{:X}, instruction 0x{:X} ({})", pc, MemoryReadCode(pc).value(), disassemble(*parent, pc, nullptr));
        }
    }

    void CallSVC(uint32_t) override {
        cpu->svc_called = true;
        cpu->jit->HaltExecution(Dynarmic::HaltReason::UserDefined8);
    }

    void AddTicks(uint64_t ticks) override {}

    uint64_t GetTicksRemaining() override {
        return 1ull << 60;
    }
};

static Dynarmic::ExclusiveMonitor shared_monitor(MAX_CORE_COUNT);

#if defined(VITA3K_PLATFORM_IOS)
static std::atomic_bool ios_fast_cpu{ false };
// Accurate CPU (per game): Dynarmic's IR optimisations (constant propagation, get/set elimination,
// miscellaneous IR passes) are left out; the control-flow ones (block linking, return stack buffer,
// fast dispatch) stay, so the cost is moderate. For games whose CPU-side math comes out wrong with
// them (Madden NFL 13's faces, a best guess: the body skins fine, the separately animated face melts).
static std::atomic_bool ios_accurate_cpu{ false };
void set_ios_accurate_cpu(bool enabled) {
    ios_accurate_cpu = enabled;
    LOG_INFO("Accurate CPU (no IR optimisations): {}", enabled ? "on" : "off");
}

void set_ios_fast_cpu(bool enabled) {
    ios_fast_cpu = enabled;
    LOG_INFO("Fast CPU (floating-point shortcuts): {}", enabled ? "on" : "off");
}
#endif

std::unique_ptr<Dynarmic::A32::Jit> DynarmicCPU::make_jit() {
    Dynarmic::A32::UserConfig config{};
    config.arch_version = Dynarmic::A32::ArchVersion::v7;
    config.callbacks = cb.get();
    if (parent->mem->use_page_table) {
        config.page_table = (log_mem || !cpu_opt) ? nullptr : reinterpret_cast<decltype(config.page_table)>(parent->mem->page_table.get());
        config.absolute_offset_page_table = true;
    } else if (!log_mem && cpu_opt) {
        config.fastmem_pointer = std::bit_cast<uintptr_t>(parent->mem->memory.get());
    }
    config.hook_hint_instructions = true;
    config.global_monitor = &shared_monitor;
    config.coprocessors[15] = cp15;
    config.processor_id = core_id;
    config.optimizations = cpu_opt ? Dynarmic::all_safe_optimizations : Dynarmic::no_optimizations;
#if defined(VITA3K_PLATFORM_IOS)
    if (cpu_opt && ios_accurate_cpu)
        config.optimizations = Dynarmic::OptimizationFlag::BlockLinking | Dynarmic::OptimizationFlag::ReturnStackBuffer
            | Dynarmic::OptimizationFlag::FastDispatch;
    if (cpu_opt && ios_fast_cpu)
        config.optimizations |= Dynarmic::OptimizationFlag::Unsafe_InaccurateNaN | Dynarmic::OptimizationFlag::Unsafe_ReducedErrorFP
            | Dynarmic::OptimizationFlag::Unsafe_IgnoreStandardFPCRValue;
#endif
    config.enable_cycle_counting = false;
#if defined(VITA3K_PLATFORM_IOS)
    // From Tsubomi: Vita3K owns one Dynarmic JIT per guest thread. On iOS 26+ each cache also has a
    // same-sized writable vm_remap alias, so the 128 MiB default scales poorly. 16 MiB stays above
    // Dynarmic's approximate 8 MiB minimum; the backend clears the cache when it fills up.
    constexpr std::size_t IOS_CODE_CACHE_SIZE = 16 * 1024 * 1024;
    config.code_cache_size = IOS_CODE_CACHE_SIZE;
#endif

#if defined(VITA3K_PLATFORM_IOS) && defined(__aarch64__)
    // StikDebug services oaknut's BRK #0xf00d while the JIT constructor maps its cache. Serialize this
    // so simultaneous guest-thread creation cannot issue overlapping debugger requests.
    static std::mutex jit_creation_mutex;
    static uint64_t jit_creation_count = 0;
    const std::lock_guard lock(jit_creation_mutex);
    const uint64_t allocation_id = ++jit_creation_count;
    LOG_INFO("iOS Dynarmic JIT cache #{} allocating: core={} size={} MiB", allocation_id, core_id, config.code_cache_size / (1024 * 1024));
    auto jit = std::make_unique<Dynarmic::A32::Jit>(config);
    LOG_INFO("iOS Dynarmic JIT cache #{} ready", allocation_id);
    return jit;
#else
    return std::make_unique<Dynarmic::A32::Jit>(config);
#endif
}

DynarmicCPU::DynarmicCPU(CPUState *state, std::size_t processor_id, bool cpu_opt)
    : parent(state)
    , cb(std::make_unique<ArmDynarmicCallback>(*state, *this))
    , cp15(std::make_shared<ArmDynarmicCP15>())
    , core_id(processor_id)
    , cpu_opt(cpu_opt) {
    jit = make_jit();
}

DynarmicCPU::~DynarmicCPU() = default;

CPUStop DynarmicCPU::run() {
    halted = false;
    break_ = false;
    svc_called = false;
    // Run until the JIT stops for something other than a step or a cache invalidation
    Dynarmic::HaltReason reason;
    do {
        reason = jit->Run();
    } while (reason == Dynarmic::HaltReason::Step || reason == Dynarmic::HaltReason::CacheInvalidation);
    // The import's NID is the word after the SVC, and a halted run stopped at the return address
    const uint32_t nid = svc_called ? *Ptr<uint32_t>(get_pc() + 4).get(*parent->mem) : 0;
    return { .kernel_call = svc_called, .nid = nid, .returned = halted };
}

CPUStop DynarmicCPU::step() {
    svc_called = false;
    jit->Step();
    const uint32_t nid = svc_called ? *Ptr<uint32_t>(get_pc() + 4).get(*parent->mem) : 0;
    return { .kernel_call = svc_called, .nid = nid };
}

bool DynarmicCPU::hit_breakpoint() {
    return break_;
}

void DynarmicCPU::trigger_breakpoint() {
    break_ = true;
    stop();
}

void DynarmicCPU::set_log_code(bool log) {
    if (log_code == log)
        return;

    log_code = log;
    jit = make_jit();
}

void DynarmicCPU::set_log_mem(bool log) {
    if (log_mem == log)
        return;

    log_mem = log;
    jit = make_jit();
}

bool DynarmicCPU::get_log_mem() {
    return log_mem;
}

void DynarmicCPU::stop() {
    jit->HaltExecution();
}

uint32_t DynarmicCPU::get_reg(uint8_t idx) {
    return jit->Regs()[idx];
}

uint32_t DynarmicCPU::get_sp() {
    return jit->Regs()[13];
}

uint32_t DynarmicCPU::get_pc() {
    return jit->Regs()[15];
}

void DynarmicCPU::set_reg(uint8_t idx, uint32_t val) {
    jit->Regs()[idx] = val;
}

void DynarmicCPU::set_cpsr(uint32_t val) {
    jit->SetCpsr(val);
}

uint32_t DynarmicCPU::get_tpidruro() {
    return cp15->tpidruro;
}

void DynarmicCPU::set_tpidruro(uint32_t val) {
    cp15->tpidruro = val;
}

uint32_t DynarmicCPU::get_tpidrurw() {
    return cp15->tpidrurw;
}

void DynarmicCPU::set_tpidrurw(uint32_t val) {
    cp15->tpidrurw = val;
}

void DynarmicCPU::set_pc(uint32_t val) {
    if (val & 1) {
        set_cpsr(get_cpsr() | 0x20);
        val = val & 0xFFFFFFFE;
    } else {
        set_cpsr(get_cpsr() & 0xFFFFFFDF);
        val = val & 0xFFFFFFFC;
    }
    jit->Regs()[15] = val;
}

void DynarmicCPU::set_lr(uint32_t val) {
    jit->Regs()[14] = val;
}

void DynarmicCPU::set_sp(uint32_t val) {
    jit->Regs()[13] = val;
}

uint32_t DynarmicCPU::get_cpsr() {
    return jit->Cpsr();
}

uint32_t DynarmicCPU::get_fpscr() {
    return jit->Fpscr();
}

void DynarmicCPU::set_fpscr(uint32_t val) {
    jit->SetFpscr(val);
}

CPUContext DynarmicCPU::save_context() {
    CPUContext ctx;
    ctx.cpu_registers = jit->Regs();
    ctx.fpu_registers = std::bit_cast<std::array<float, 64>>(jit->ExtRegs());
    ctx.fpscr = jit->Fpscr();
    ctx.cpsr = jit->Cpsr();
    return ctx;
}

void DynarmicCPU::load_context(const CPUContext &ctx) {
    jit->Regs() = ctx.cpu_registers;
    jit->ExtRegs() = std::bit_cast<std::array<uint32_t, 64>>(ctx.fpu_registers);
    jit->SetCpsr(ctx.cpsr);
    jit->SetFpscr(ctx.fpscr);
}

uint32_t DynarmicCPU::get_lr() {
    return jit->Regs()[14];
}

float DynarmicCPU::get_float_reg(uint8_t idx) {
    return std::bit_cast<float>(jit->ExtRegs()[idx]);
}

void DynarmicCPU::set_float_reg(uint8_t idx, float val) {
    jit->ExtRegs()[idx] = std::bit_cast<uint32_t>(val);
}

bool DynarmicCPU::is_thumb_mode() {
    return jit->Cpsr() & 0x20;
}

std::size_t DynarmicCPU::processor_id() const {
    return core_id;
}

void DynarmicCPU::invalidate_jit_cache(Address start, size_t length) {
    jit->InvalidateCacheRange(start, length);
}

void DynarmicCPU::clear_exclusive() {
    shared_monitor.ClearProcessor(core_id);
}
