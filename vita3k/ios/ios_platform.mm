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

// Small UIKit/Foundation helpers used by the C++ side of the iOS port

#include "ios_platform.h"

#import <AVFoundation/AVFoundation.h>
#import <Photos/Photos.h>
#include <objc/runtime.h>
#import <Foundation/Foundation.h>
#include <os/proc.h>
#include <mach/mach.h>
#import <UIKit/UIKit.h>

#include <atomic>
#include <cstdint>
#include <mutex>
#include <vector>
#include <sys/sysctl.h>
#include <unistd.h>

// Implemented in Swift (ui/LibraryHost.swift)
extern "C" void v3k_ui_show(void);
extern "C" void v3k_ui_hide(void);
extern "C" void v3k_controls_toast(const char *message);

// Not in the public SDK headers, but a stable syscall wrapper used by every iOS JIT app
extern "C" int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);

namespace ios {

std::string get_documents_path() {
    @autoreleasepool {
        NSArray<NSURL *> *urls = [[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask];
        return [urls.firstObject.path UTF8String];
    }
}

std::string get_bundle_resources_path() {
    @autoreleasepool {
        return [[NSBundle mainBundle].resourcePath UTF8String];
    }
}

std::string get_os_version() {
    @autoreleasepool {
        UIDevice *device = [UIDevice currentDevice];
        return std::string([device.systemName UTF8String]) + " " + [device.systemVersion UTF8String];
    }
}

std::string get_device_model() {
    // hw.machine gives the model identifier, e.g. "iPhone15,2"
    char machine[64] = {};
    size_t size = sizeof(machine);
    if (sysctlbyname("hw.machine", machine, &size, nullptr, 0) == 0 && machine[0])
        return machine;
    return "Unknown Apple device";
}

namespace {
std::mutex pending_launch_mutex;
std::string pending_launch;
} // namespace

void set_pending_launch(const std::string &title_id) {
    std::lock_guard lock(pending_launch_mutex);
    pending_launch = title_id;
}

std::string run_library_until_launch() {
    {
        std::lock_guard lock(pending_launch_mutex);
        pending_launch.clear();
    }
    v3k_ui_show();
    for (;;) {
        @autoreleasepool {
            // Same pattern SDL uses to pump UIKit events: run the main loop in short slices
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, true);
        }
        std::lock_guard lock(pending_launch_mutex);
        if (!pending_launch.empty()) {
            std::string title_id = pending_launch;
            pending_launch.clear();
            v3k_ui_hide();
            return title_id;
        }
    }
}

namespace {
std::atomic_bool in_background{ false };
}

std::string resolve_custom_storage(std::string &note) {
    @autoreleasepool {
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        NSData *bookmark = [defaults dataForKey:@"v3k.storageBookmark"];
        if (!bookmark)
            return {};
        BOOL stale = NO;
        NSError *error = nil;
        NSURL *url = [NSURL URLByResolvingBookmarkData:bookmark options:0 relativeToURL:nil
                                   bookmarkDataIsStale:&stale error:&error];
        if (!url) {
            note = "The custom storage location can't be reached (is the drive connected?). Using internal storage.";
            return {};
        }
        // Access stays open for the whole run: games are read from there
        [url startAccessingSecurityScopedResource];
        BOOL is_directory = NO;
        if (![NSFileManager.defaultManager fileExistsAtPath:url.path isDirectory:&is_directory] || !is_directory) {
            note = "The custom storage folder is missing (is the drive connected?). Using internal storage.";
            return {};
        }
        if (stale) {
            NSData *fresh = [url bookmarkDataWithOptions:0 includingResourceValuesForKeys:nil relativeToURL:nil error:nil];
            if (fresh)
                [defaults setObject:fresh forKey:@"v3k.storageBookmark"];
        }
        return url.path.UTF8String;
    }
}

void set_screen_always_on(bool on) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIApplication.sharedApplication.idleTimerDisabled = on;
    });
}

void observe_app_state() {
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:nil
                    usingBlock:^(NSNotification *) { in_background = true; }];
    [center addObserverForName:UIApplicationWillEnterForegroundNotification object:nil queue:nil
                    usingBlock:^(NSNotification *) { in_background = false; }];
}

bool app_in_background() {
    return in_background;
}

// From Tsubomi (vita3k_ios_configure_audio_session)
std::string configure_audio_session() {
    @autoreleasepool {
        NSError *error = nil;
        AVAudioSession *session = AVAudioSession.sharedInstance;
        std::string result;
        // Playback so audio keeps running with the mute switch on; MixWithOthers keeps us polite
        if (![session setCategory:AVAudioSessionCategoryPlayback mode:AVAudioSessionModeDefault
                          options:AVAudioSessionCategoryOptionMixWithOthers error:&error]) {
            result += std::string("setCategory failed: ") + (error.localizedDescription.UTF8String ?: "unknown") + ". ";
            error = nil;
        }
        [session setPreferredSampleRate:48000 error:nil];
        [session setPreferredIOBufferDuration:1024.0 / 48000.0 error:nil];
        if (![session setActive:YES error:&error])
            return result + "Audio session activation failed: " + (error.localizedDescription.UTF8String ?: "unknown");
        return result + "Audio session active (Playback), " + std::to_string(static_cast<int>(session.sampleRate)) + " Hz";
    }
}

bool is_jit_enabled() {
    constexpr unsigned int CS_OPS_STATUS = 0;
    constexpr uint32_t CS_DEBUGGED = 0x10000000;
    uint32_t flags = 0;
    if (csops(getpid(), CS_OPS_STATUS, &flags, sizeof(flags)) != 0)
        return false;
    return (flags & CS_DEBUGGED) != 0;
}

bool download(const std::string &url, std::string &data, std::string &error) {
    @autoreleasepool {
        NSURL *nsurl = [NSURL URLWithString:[NSString stringWithUTF8String:url.c_str()]];
        if (!nsurl) {
            error = "invalid URL";
            return false;
        }
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:nsurl
                                                               cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                           timeoutInterval:30];
        [request setValue:@"Vita3KiOS" forHTTPHeaderField:@"User-Agent"];

        __block NSData *body = nil;
        __block NSInteger status = 0;
        __block NSString *failure = nil;
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request
                                                                     completionHandler:^(NSData *received, NSURLResponse *response, NSError *taskError) {
            if (taskError)
                failure = taskError.localizedDescription;
            if ([response isKindOfClass:[NSHTTPURLResponse class]])
                status = ((NSHTTPURLResponse *)response).statusCode;
            body = received;
            dispatch_semaphore_signal(done);
        }];
        [task resume];
        dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);

        if (failure) {
            error = failure.UTF8String;
            return false;
        }
        if (status / 100 != 2 || !body) {
            error = "server answered HTTP " + std::to_string(status);
            return false;
        }
        data.assign(static_cast<const char *>(body.bytes), body.length);
        return true;
    }
}

ProcessStats process_stats() {
    ProcessStats stats;
    task_vm_info_data_t vm_info{};
    mach_msg_type_number_t vm_count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, reinterpret_cast<task_info_t>(&vm_info), &vm_count) == KERN_SUCCESS)
        stats.memory_used = vm_info.phys_footprint;
    stats.memory_available = os_proc_available_memory();

    thread_act_array_t threads = nullptr;
    mach_msg_type_number_t thread_count = 0;
    if (task_threads(mach_task_self(), &threads, &thread_count) == KERN_SUCCESS) {
        for (mach_msg_type_number_t i = 0; i < thread_count; i++) {
            thread_basic_info_data_t info{};
            mach_msg_type_number_t info_count = THREAD_BASIC_INFO_COUNT;
            if (thread_info(threads[i], THREAD_BASIC_INFO, reinterpret_cast<thread_info_t>(&info), &info_count) == KERN_SUCCESS
                && !(info.flags & TH_FLAGS_IDLE))
                stats.cpu_percent += info.cpu_usage * 100.0 / TH_USAGE_SCALE;
            mach_port_deallocate(mach_task_self(), threads[i]);
        }
        vm_deallocate(mach_task_self(), reinterpret_cast<vm_address_t>(threads), thread_count * sizeof(thread_t));
    }
    return stats;
}

bool volume_capacity(const std::string &path, uint64_t &total, uint64_t &available) {
    @autoreleasepool {
        NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path.c_str()]];
        NSArray *keys = @[ NSURLVolumeTotalCapacityKey, NSURLVolumeAvailableCapacityForImportantUsageKey, NSURLVolumeAvailableCapacityKey ];
        NSDictionary *values = [url resourceValuesForKeys:keys error:nil];
        NSNumber *capacity = values[NSURLVolumeTotalCapacityKey];
        // External drives don't report "important usage": use their plain free space
        NSNumber *important = values[NSURLVolumeAvailableCapacityForImportantUsageKey];
        NSNumber *plain = values[NSURLVolumeAvailableCapacityKey];
        if (!capacity)
            return false;
        total = capacity.unsignedLongLongValue;
        available = (important && important.unsignedLongLongValue > 0) ? important.unsignedLongLongValue : plain.unsignedLongLongValue;
        return true;
    }
}

bool portrait_mode_enabled() {
    NSNumber *value = [NSUserDefaults.standardUserDefaults objectForKey:@"v3k.portraitMode"];
    return value ? value.boolValue : true;
}

int interface_rotation() {
    UIWindowScene *scene = nil;
    for (UIScene *candidate in UIApplication.sharedApplication.connectedScenes) {
        if ([candidate isKindOfClass:UIWindowScene.class]) {
            scene = (UIWindowScene *)candidate;
            break;
        }
    }
    if (!scene)
        return -1;
    switch (scene.effectiveGeometry.interfaceOrientation) {
    case UIInterfaceOrientationPortrait:
        return 0;
    case UIInterfaceOrientationLandscapeRight: // phone turned anticlockwise: its top is on the left
        return 1;
    case UIInterfaceOrientationPortraitUpsideDown:
        return 2;
    case UIInterfaceOrientationLandscapeLeft:
        return 3;
    default:
        return -1;
    }
}

void save_image_to_photos(const std::string &path) {
    NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path.c_str()]];
    const auto report = [](const char *message) {
        dispatch_async(dispatch_get_main_queue(), ^{
            v3k_controls_toast(message);
        });
    };
    [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelAddOnly
                                               handler:^(PHAuthorizationStatus status) {
                                                   if (status != PHAuthorizationStatusAuthorized && status != PHAuthorizationStatusLimited) {
                                                       report("Screenshot saved in the Vita3K folder (no access to Photos)");
                                                       return;
                                                   }
                                                   [PHPhotoLibrary.sharedPhotoLibrary performChanges:^{
                                                       [PHAssetCreationRequest creationRequestForAssetFromImageAtFileURL:url];
                                                   }
                                                       completionHandler:^(BOOL success, NSError *) {
                                                           report(success ? "Screenshot saved to Photos" : "Screenshot saved in the Vita3K folder");
                                                       }];
                                               }];
}

} // namespace ios

// Launch links and Home Screen quick actions --------------------------------------------------
//
// vita3k://launch/<TITLE ID> starts a game (Shortcuts can put one on the Home Screen with its own
// icon), and long-pressing the app icon lists the last games played. SDL owns the scene delegate, so
// its URL handler is wrapped and quick-action handlers are added when the binary loads.

namespace {

std::mutex launch_request_mutex;
std::string launch_request;

std::vector<std::string> import_requests;

// "Open in Vita3K" from Files, Safari or another app: the file is installed from the library
bool take_import_url(NSURL *url) {
    if (!url.isFileURL)
        return false;
    // Opened in place: keep access for this run, the install reads it later
    [url startAccessingSecurityScopedResource];
    {
        const std::lock_guard lock(launch_request_mutex);
        import_requests.push_back(url.path.UTF8String);
    }
    [NSNotificationCenter.defaultCenter postNotificationName:@"V3KLaunchRequest" object:nil];
    return true;
}

bool take_launch_url(NSURL *url) {
    if (take_import_url(url))
        return true;
    if (![url.scheme.lowercaseString isEqualToString:@"vita3k"])
        return false;
    // vita3k://launch/PCSE00000 or vita3k://PCSE00000
    NSString *title_id = url.lastPathComponent;
    if (!title_id.length || [title_id isEqualToString:@"/"])
        title_id = url.host;
    if (!title_id.length || [title_id isEqualToString:@"launch"])
        return true;
    {
        const std::lock_guard lock(launch_request_mutex);
        launch_request = title_id.uppercaseString.UTF8String;
    }
    [NSNotificationCenter.defaultCenter postNotificationName:@"V3KLaunchRequest" object:nil];
    return true;
}

IMP original_handle_url = nullptr;
IMP original_will_connect = nullptr;

// SDL routes every URL it is given (at launch and later) through -handleURL:
void v3k_handle_url(id self, SEL cmd, NSURL *url) {
    if (take_launch_url(url))
        return;
    if (original_handle_url)
        reinterpret_cast<void (*)(id, SEL, NSURL *)>(original_handle_url)(self, cmd, url);
}

bool take_shortcut(UIApplicationShortcutItem *item) {
    NSString *title_id = (NSString *)item.userInfo[@"titleId"];
    if (!title_id.length)
        return false;
    return take_launch_url([NSURL URLWithString:[@"vita3k://launch/" stringByAppendingString:title_id]]);
}

// Quick action while Vita3K is running
void v3k_perform_shortcut(id, SEL, UIWindowScene *, UIApplicationShortcutItem *item, void (^completion)(BOOL)) {
    const bool handled = take_shortcut(item);
    if (completion)
        completion(handled);
}

// Quick action that launched Vita3K
void v3k_will_connect(id self, SEL cmd, UIScene *scene, UISceneSession *session, UISceneConnectionOptions *options) {
    if (options.shortcutItem)
        take_shortcut(options.shortcutItem);
    if (original_will_connect)
        reinterpret_cast<void (*)(id, SEL, UIScene *, UISceneSession *, UISceneConnectionOptions *)>(original_will_connect)(self, cmd, scene, session, options);
}

} // namespace

@interface V3KLaunchLinks : NSObject
@end

@implementation V3KLaunchLinks
+ (void)load {
    // SDL's scene delegate (SDL_uikitappdelegate.m) is also the app delegate
    Class delegate = NSClassFromString(@"SDLUIKitSceneDelegate");
    if (!delegate)
        return;
    if (Method method = class_getInstanceMethod(delegate, NSSelectorFromString(@"handleURL:")))
        original_handle_url = method_setImplementation(method, reinterpret_cast<IMP>(v3k_handle_url));
    if (Method method = class_getInstanceMethod(delegate, @selector(scene:willConnectToSession:options:)))
        original_will_connect = method_setImplementation(method, reinterpret_cast<IMP>(v3k_will_connect));
    class_addMethod(delegate, @selector(windowScene:performActionForShortcutItem:completionHandler:),
        reinterpret_cast<IMP>(v3k_perform_shortcut), "v@:@@@?");
}
@end

extern "C" char *v3k_take_import_request(void) {
    const std::lock_guard lock(launch_request_mutex);
    if (import_requests.empty())
        return nullptr;
    char *copy = strdup(import_requests.front().c_str());
    import_requests.erase(import_requests.begin());
    return copy;
}

extern "C" char *v3k_take_launch_request(void) {
    const std::lock_guard lock(launch_request_mutex);
    if (launch_request.empty())
        return nullptr;
    char *copy = strdup(launch_request.c_str());
    launch_request.clear();
    return copy;
}
