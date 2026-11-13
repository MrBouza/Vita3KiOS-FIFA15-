// Vita3K project
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

// The RAM helper extension (V3KRamHelper.appex): a separate process with its own memory limit that
// lends memory to Vita3K. See protocol.h.

#import <Foundation/Foundation.h>
#import <mach/mach.h>
#import <objc/runtime.h>
#import <os/proc.h>
#import <xpc/xpc.h>

#include <vector>

#import "protocol.h"

// The xpc endpoint travels inside an NSXPCListenerEndpoint (the only endpoint NSExtensionItem can
// carry); its private _endpoint property holds the raw xpc object
@interface NSXPCListenerEndpoint (V3KRamHelper)
@property (nonatomic, setter=_setEndpoint:) xpc_object_t _endpoint;
@end

static xpc_endpoint_t v3k_unwrap_endpoint(NSXPCListenerEndpoint *wrapper) {
    xpc_object_t inner = wrapper._endpoint;
    if (!inner || xpc_get_type(inner) != XPC_TYPE_ENDPOINT)
        return nil;
    return (xpc_endpoint_t)inner;
}

extern "C" kern_return_t mach_vm_allocate(vm_map_t target, mach_vm_address_t *address, mach_vm_size_t size, int flags);
extern "C" kern_return_t mach_vm_deallocate(vm_map_t target, mach_vm_address_t address, mach_vm_size_t size);
extern "C" int NSExtensionMain(int argc, char *argv[]);

#ifndef VM_FLAGS_PURGABLE
#define VM_FLAGS_PURGABLE 0x2
#endif

namespace {

struct Region {
    mach_vm_address_t base;
    mach_vm_size_t size;
};

std::vector<Region> g_regions;

void release_regions() {
    for (const Region &region : g_regions)
        mach_vm_deallocate(mach_task_self(), region.base, region.size);
    g_regions.clear();
}

// Purgeable memory belongs to (and is charged to) the process that allocated it, whoever maps it
xpc_object_t create_region(uint64_t size, NSString **error) {
    if (size == 0 || size > 4 * V3K_RAM_HELPER_CHUNK) {
        *error = @"Bad region size";
        return nil;
    }
    mach_vm_address_t address = 0;
    const kern_return_t kr = mach_vm_allocate(mach_task_self(), &address, size, VM_FLAGS_ANYWHERE | VM_FLAGS_PURGABLE);
    if (kr != KERN_SUCCESS) {
        *error = [NSString stringWithFormat:@"mach_vm_allocate: %s", mach_error_string(kr)];
        return nil;
    }
    xpc_object_t shmem = xpc_shmem_create(reinterpret_cast<void *>(address), static_cast<size_t>(size));
    if (!shmem) {
        mach_vm_deallocate(mach_task_self(), address, size);
        *error = @"xpc_shmem_create failed";
        return nil;
    }
    g_regions.push_back({ address, size });
    return shmem;
}

// Built-in JIT: builtin_jit_helper.swift (StikJIT), present when the build bundled StikJIT
#if V3K_HELPER_HAS_STIKJIT
extern "C" char *v3k_helper_enable_jit(int32_t pid, const uint8_t *pairing, long pairing_length, const char *script_base64, bool force_script, int32_t port, void (*progress)(const char *));
#endif

xpc_connection_t g_channel = nil;

void send_jit_progress(const char *text) {
    if (!g_channel || !text)
        return;
    xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(message, V3K_RAM_KEY_OP, V3K_RAM_OP_JIT_PROGRESS);
    xpc_dictionary_set_string(message, V3K_RAM_KEY_TEXT, text);
    xpc_connection_send_message(g_channel, message);
}

// The attach blocks (network, a Developer Disk Image download, the debugger session): one at a time, on
// its own queue, never on the connection's
void enable_jit(xpc_connection_t channel, xpc_object_t message, xpc_object_t reply) {
#if V3K_HELPER_HAS_STIKJIT
    static dispatch_queue_t queue = dispatch_queue_create("hinoki.builtin-jit", DISPATCH_QUEUE_SERIAL);
    const int32_t pid = static_cast<int32_t>(xpc_dictionary_get_int64(message, V3K_RAM_KEY_PID));
    size_t length = 0;
    const void *bytes = xpc_dictionary_get_data(message, V3K_RAM_KEY_PAIRING, &length);
    NSData *pairing = bytes ? [NSData dataWithBytes:bytes length:length] : nil;
    const char *script = xpc_dictionary_get_string(message, V3K_RAM_KEY_SCRIPT);
    NSString *script_copy = script ? @(script) : nil;
    const bool force = xpc_dictionary_get_bool(message, V3K_RAM_KEY_FORCE);
    const int32_t port = static_cast<int32_t>(xpc_dictionary_get_uint64(message, V3K_RAM_KEY_PORT));
    dispatch_async(queue, ^{
        char *error = v3k_helper_enable_jit(pid, static_cast<const uint8_t *>(pairing.bytes), static_cast<long>(pairing.length),
            script_copy.UTF8String, force, port, send_jit_progress);
        if (error) {
            xpc_dictionary_set_string(reply, V3K_RAM_KEY_ERROR, error);
            free(error);
        }
        xpc_connection_send_message(channel, reply);
    });
#else
    xpc_dictionary_set_string(reply, V3K_RAM_KEY_ERROR, "This build of Hinoki has no built-in JIT");
    xpc_connection_send_message(channel, reply);
#endif
}

uint64_t footprint() {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, reinterpret_cast<task_info_t>(&info), &count) != KERN_SUCCESS)
        return 0;
    return info.phys_footprint;
}

void handle_message(xpc_connection_t channel, xpc_object_t message) {
    if (xpc_get_type(message) != XPC_TYPE_DICTIONARY)
        return;
    const char *op = xpc_dictionary_get_string(message, V3K_RAM_KEY_OP);
    if (!op)
        return;
    xpc_object_t reply = xpc_dictionary_create_reply(message);
    if (!reply)
        return;

    if (strcmp(op, V3K_RAM_OP_CREATE) == 0) {
        NSString *error = nil;
        xpc_object_t shmem = create_region(xpc_dictionary_get_uint64(message, V3K_RAM_KEY_SIZE), &error);
        if (shmem)
            xpc_dictionary_set_value(reply, V3K_RAM_KEY_SHMEM, shmem);
        else
            xpc_dictionary_set_string(reply, V3K_RAM_KEY_ERROR, error.UTF8String);
    } else if (strcmp(op, V3K_RAM_OP_RELEASE) == 0) {
        release_regions();
    } else if (strcmp(op, V3K_RAM_OP_AVAILABLE) == 0) {
        xpc_dictionary_set_uint64(reply, V3K_RAM_KEY_AVAILABLE, static_cast<uint64_t>(os_proc_available_memory()));
    } else if (strcmp(op, V3K_RAM_OP_FOOTPRINT) == 0) {
        xpc_dictionary_set_uint64(reply, V3K_RAM_KEY_FOOTPRINT, footprint());
    } else if (strcmp(op, V3K_RAM_OP_ENABLE_JIT) == 0) {
        enable_jit(channel, message, reply);
        return; // answered when the attach is over
    } else {
        xpc_dictionary_set_string(reply, V3K_RAM_KEY_ERROR, "Unknown operation");
    }
    xpc_connection_send_message(channel, reply);
}

void ignore_class_check() {}

} // namespace

// NSXPCListenerEndpoint is not on the allow list of the extension request's decoder: without this
// the endpoint Vita3K sends arrives as nil
__attribute__((constructor)) static void v3k_allow_endpoint_decoding() {
    Class decoder = NSClassFromString(@"NSXPCDecoder");
    Method method = class_getInstanceMethod(decoder, NSSelectorFromString(@"_validateAllowedClass:forKey:allowingInvocations:"));
    if (method)
        method_setImplementation(method, reinterpret_cast<IMP>(ignore_class_check));
}

@interface V3KRamHelperHandler : NSObject <NSExtensionRequestHandling>
@end

@implementation V3KRamHelperHandler {
    xpc_connection_t _channel;
}

- (void)beginRequestWithExtensionContext:(NSExtensionContext *)context {
    // The request never completes: the helper lives until Vita3K ends it (or goes away)
    NSExtensionItem *item = (NSExtensionItem *)context.inputItems.firstObject;
    id wrapper = item.userInfo[@"endpoint"];
    if (![wrapper isKindOfClass:NSXPCListenerEndpoint.class]) {
        NSLog(@"V3KRamHelper: the request carried no endpoint");
        return;
    }
    xpc_endpoint_t endpoint = v3k_unwrap_endpoint(wrapper);
    if (!endpoint) {
        NSLog(@"V3KRamHelper: the endpoint could not be unwrapped");
        return;
    }
    _channel = xpc_connection_create_from_endpoint(endpoint);
    xpc_connection_t channel = _channel;
    g_channel = channel;
    xpc_connection_set_event_handler(channel, ^(xpc_object_t event) {
        if (xpc_get_type(event) == XPC_TYPE_ERROR) {
            // Vita3K closed or crashed: nothing left to lend memory to
            exit(0);
        }
        handle_message(channel, event);
    });
    xpc_connection_resume(channel);

    xpc_object_t hello = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(hello, V3K_RAM_KEY_OP, V3K_RAM_OP_HELLO);
    xpc_dictionary_set_int64(hello, "pid", getpid());
    xpc_dictionary_set_uint64(hello, V3K_RAM_KEY_AVAILABLE, static_cast<uint64_t>(os_proc_available_memory()));
    xpc_connection_send_message(channel, hello);
    NSLog(@"V3KRamHelper: ready, pid %d, %llu MiB available", getpid(), static_cast<unsigned long long>(os_proc_available_memory() >> 20));
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return NSExtensionMain(argc, argv);
    }
}
