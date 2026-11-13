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

// Built-in JIT, app side. A copy of the helper extension (the RAM helper's, a separate process) runs
// StikJIT: it connects to the device through LocalDevVPN with the player's pairing file, mounts the
// Developer Disk Image if needed, and attaches debugserver to Hinoki. Hinoki notices the debugger and
// prepares its JIT memory as it does with StikDebug (LibraryHost.watchForJITScript), the script lets
// it go, and the helper ends. The layout follows StikJIT's INTEGRATION.md (host app + helper).

#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <dlfcn.h>
#import <xpc/xpc.h>

#include "builtin_jit.h"
#include "protocol.h"

#include <atomic>
#include <cstring>
#include <string>

extern "C" void v3k_ram_helpers_log(bool warning, const char *message);

@interface NSXPCListenerEndpoint (V3KBuiltinJIT)
@property (nonatomic, setter=_setEndpoint:) xpc_object_t _endpoint;
@end

@protocol V3KBuiltinJITExtension <NSObject>
@property (nonatomic, strong, readwrite) NSArray *preferredLanguages;
+ (id<V3KBuiltinJITExtension>)extensionWithIdentifier:(NSString *)identifier error:(NSError **)error;
- (void)beginExtensionRequestWithInputItems:(NSArray *)items completion:(void (^)(NSUUID *))callback;
- (void)_kill:(int)signal;
@end

// Security SPI (as StikJIT's guide does): the entitlement the debugger needs, read from this process
typedef struct __SecTask *V3KSecTaskRef;
extern "C" V3KSecTaskRef SecTaskCreateFromSelf(CFAllocatorRef allocator);
extern "C" CFTypeRef SecTaskCopyValueForEntitlement(V3KSecTaskRef task, CFStringRef entitlement, CFErrorRef *error);

namespace {

std::atomic<bool> g_busy{ false };

void log_line(bool warning, const std::string &text) {
    v3k_ram_helpers_log(warning, ("Built-in JIT: " + text).c_str());
}

bool in_livecontainer() {
    return getenv("LC_HOME_PATH") != nullptr || [NSBundle.mainBundle.bundlePath containsString:@"LiveContainer"];
}

bool has_get_task_allow() {
    V3KSecTaskRef task = SecTaskCreateFromSelf(kCFAllocatorDefault);
    if (!task)
        return false;
    CFTypeRef value = SecTaskCopyValueForEntitlement(task, CFSTR("get-task-allow"), nullptr);
    CFRelease(task);
    const bool allowed = value && CFGetTypeID(value) == CFBooleanGetTypeID() && CFBooleanGetValue(static_cast<CFBooleanRef>(value));
    if (value)
        CFRelease(value);
    return allowed;
}

NSString *helper_identifier() {
    NSArray<NSURL *> *contents = [NSFileManager.defaultManager contentsOfDirectoryAtURL:NSBundle.mainBundle.builtInPlugInsURL
                                                             includingPropertiesForKeys:nil
                                                                                options:0
                                                                                  error:nil];
    for (NSURL *url in contents) {
        if (![url.pathExtension isEqualToString:@"appex"])
            continue;
        NSBundle *bundle = [NSBundle bundleWithURL:url];
        if ([bundle.infoDictionary[@"NSExtension"][@"NSExtensionPrincipalClass"] isEqualToString:@V3K_RAM_HELPER_PRINCIPAL])
            return bundle.bundleIdentifier;
    }
    return nil;
}

void run(NSData *pairing, NSString *script, bool force, void (*progress)(const char *), void (*done)(bool, const char *)) {
    const auto finish = [&](bool ok, const std::string &message) {
        log_line(!ok, ok ? "JIT enabled" : message);
        g_busy = false;
        if (done)
            done(ok, ok ? nullptr : message.c_str());
    };

    NSString *identifier = helper_identifier();
    if (!identifier)
        return finish(false, "The helper extension is missing from this copy of Hinoki (reinstall it without removing app extensions)");

    Class extension_class = NSClassFromString(@"NSExtension");
    if (!extension_class) {
        dlopen("/System/Library/Frameworks/ExtensionFoundation.framework/ExtensionFoundation", RTLD_LAZY | RTLD_GLOBAL);
        extension_class = NSClassFromString(@"NSExtension");
    }
    if (!extension_class)
        return finish(false, "This iOS version has no way to start the helper");

    // Our own listener: the helper connects to it, says hello, then receives the request
    dispatch_queue_t queue = dispatch_queue_create("hinoki.builtin-jit.host", DISPATCH_QUEUE_SERIAL);
    __block xpc_connection_t helper = nil;
    dispatch_semaphore_t connected = dispatch_semaphore_create(0);
    xpc_connection_t listener = xpc_connection_create(NULL, queue);
    xpc_connection_set_event_handler(listener, ^(xpc_object_t event) {
        if (xpc_get_type(event) != XPC_TYPE_CONNECTION)
            return;
        xpc_connection_t connection = (xpc_connection_t)event;
        xpc_connection_set_event_handler(connection, ^(xpc_object_t message) {
            if (xpc_get_type(message) != XPC_TYPE_DICTIONARY)
                return;
            const char *op = xpc_dictionary_get_string(message, V3K_RAM_KEY_OP);
            if (!op)
                return;
            if (strcmp(op, V3K_RAM_OP_HELLO) == 0) {
                if (!helper) {
                    helper = connection;
                    dispatch_semaphore_signal(connected);
                }
            } else if (strcmp(op, V3K_RAM_OP_JIT_PROGRESS) == 0) {
                const char *text = xpc_dictionary_get_string(message, V3K_RAM_KEY_TEXT);
                if (text) {
                    log_line(false, text);
                    if (progress)
                        progress(text);
                }
            }
        });
        xpc_connection_resume(connection);
    });
    xpc_connection_resume(listener);

    NSError *error = nil;
    id<V3KBuiltinJITExtension> extension = [(Class<V3KBuiltinJITExtension>)extension_class extensionWithIdentifier:identifier error:&error];
    if (!extension) {
        xpc_connection_cancel(listener);
        return finish(false, std::string("iOS could not find the helper extension: ") + (error.localizedDescription.UTF8String ?: "no reason given"));
    }
    extension.preferredLanguages = @[];
    NSXPCListenerEndpoint *wrapper = [NSXPCListenerEndpoint new];
    wrapper._endpoint = xpc_endpoint_create(listener);
    NSExtensionItem *item = [NSExtensionItem new];
    item.userInfo = @{ @"endpoint" : wrapper, @"mode" : @"jit" };

    if (progress)
        progress("Starting the helper");
    [extension beginExtensionRequestWithInputItems:@[ item ] completion:^(NSUUID *) {}];
    if (dispatch_semaphore_wait(connected, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)) != 0) {
        [extension _kill:SIGKILL];
        xpc_connection_cancel(listener);
        return finish(false, "The helper didn't start (iOS refused to run it)");
    }

    xpc_object_t request = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(request, V3K_RAM_KEY_OP, V3K_RAM_OP_ENABLE_JIT);
    xpc_dictionary_set_int64(request, V3K_RAM_KEY_PID, getpid());
    xpc_dictionary_set_data(request, V3K_RAM_KEY_PAIRING, pairing.bytes, pairing.length);
    if (script.length)
        xpc_dictionary_set_string(request, V3K_RAM_KEY_SCRIPT, script.UTF8String);
    xpc_dictionary_set_bool(request, V3K_RAM_KEY_FORCE, force);

    __block std::string result = "The helper stopped before it answered";
    __block bool ok = false;
    dispatch_semaphore_t answered = dispatch_semaphore_create(0);
    xpc_connection_send_message_with_reply(helper, request, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(xpc_object_t reply) {
        if (xpc_get_type(reply) == XPC_TYPE_DICTIONARY) {
            const char *message = xpc_dictionary_get_string(reply, V3K_RAM_KEY_ERROR);
            ok = message == nullptr;
            result = message ? message : "";
        }
        dispatch_semaphore_signal(answered);
    });
    // The first time, the Developer Disk Image is downloaded (a few hundred MB on slow networks)
    if (dispatch_semaphore_wait(answered, dispatch_time(DISPATCH_TIME_NOW, 600 * NSEC_PER_SEC)) != 0)
        result = "Timed out after 10 minutes";

    [extension _kill:SIGKILL];
    xpc_connection_cancel(listener);
    finish(ok, result);
}

} // namespace

const char *v3k_builtin_jit_unavailable_reason(void) {
    if (in_livecontainer())
        return "Not inside LiveContainer: use StikDebug there (with LiveContainer's own bundle ID), or install Hinoki on its own";
    if (!helper_identifier())
        return "The helper extension is missing from this copy of Hinoki (reinstall it without removing app extensions)";
    if (!has_get_task_allow())
        return "Hinoki was signed without get-task-allow, so no debugger may attach (sign it with a development certificate, as SideStore does)";
    return nullptr;
}

bool v3k_builtin_jit_busy(void) {
    return g_busy;
}

void v3k_builtin_jit_start(const uint8_t *pairing, size_t pairing_length, const char *script_base64, bool force_script,
    void (*progress)(const char *text), void (*done)(bool ok, const char *message)) {
    if (g_busy.exchange(true)) {
        if (done)
            done(false, "Already enabling JIT");
        return;
    }
    NSData *pairing_data = [NSData dataWithBytes:pairing length:pairing_length];
    NSString *script = script_base64 ? @(script_base64) : nil;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            run(pairing_data, script, force_script, progress, done);
        }
    });
}
