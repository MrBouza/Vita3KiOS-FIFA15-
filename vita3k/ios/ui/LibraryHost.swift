// Vita3K emulator project
// Copyright (C) 2026 Vita3K team
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import UIKit

/// Owns the window that shows the SwiftUI library. SDL creates its own window for the game, so the
/// library window is hidden while a game runs and shown again when the game exits.
@MainActor
enum LibraryHost {
    static var window: UIWindow?
    static let model = LibraryModel()

    static func show() {
        BackgroundMotion.shared.setActive(true)
        if window == nil {
            let newWindow: UIWindow
            if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
                newWindow = UIWindow(windowScene: scene)
            } else {
                newWindow = UIWindow(frame: UIScreen.main.bounds)
            }
            let controller = UIHostingController(rootView: LibraryView().environmentObject(model))
            controller.view.backgroundColor = .black
            newWindow.rootViewController = controller
            newWindow.overrideUserInterfaceStyle = .dark
            window = newWindow
        }
        model.reload()
        updateQuickActions()
        let firstShow = !hasShown
        hasShown = true
        if firstShow {
            NotificationCenter.default.addObserver(forName: Notification.Name("V3KLaunchRequest"), object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { takeLaunchRequest() }
            }
        }
        // A launch link or quick action may have opened the app; give JIT setup a moment to begin
        DispatchQueue.main.asyncAfter(deadline: .now() + (firstShow ? 0.6 : 0.3)) { takeLaunchRequest() }
        window?.alpha = 0
        window?.isHidden = false
        window?.makeKeyAndVisible()
        UIView.animate(withDuration: firstShow ? 0.35 : 0.2, delay: 0, options: [.curveEaseOut]) {
            window?.alpha = 1
        }
        if firstShow && v3k_jit_can_request() {
            // Prepare JIT right away (StikDebug briefly pauses the app while it works), and start the
            // menu music only once that's done, so the music doesn't stutter as it begins
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                v3k_jit_request()
                model.reload()
                startMusicWhenJITIsReady()
            }
        } else {
            MenuMusic.shared.libraryShown()
        }
    }

    private static var hasShown = false
    private static var externalLaunch: String?

    /// vita3k://launch/<ID> links and Home Screen quick actions
    static func takeLaunchRequest() {
        if let titleId = takeString(v3k_take_launch_request()) {
            externalLaunch = titleId
        }
        guard let titleId = externalLaunch else { return }
        // Only from the library: a running game isn't interrupted
        guard window?.isHidden == false else {
            externalLaunch = nil
            return
        }
        if v3k_jit_preparing() || model.settingUpJIT {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { takeLaunchRequest() }
            return
        }
        externalLaunch = nil
        model.reload()
        if let app = model.apps.first(where: { $0.titleId.caseInsensitiveCompare(titleId) == .orderedSame }) {
            model.launchRequested = app
        } else {
            model.lastMessage = "\(titleId) isn't installed in Vita3K."
        }
    }

    /// Long-pressing the app icon lists the last games played
    static func updateQuickActions() {
        let recent = model.apps.filter { $0.lastPlayed > 0 }.sorted { $0.lastPlayed > $1.lastPlayed }.prefix(4)
        UIApplication.shared.shortcutItems = recent.map { app in
            UIApplicationShortcutItem(type: "org.vita3k.ios.launch", localizedTitle: app.title, localizedSubtitle: app.titleId,
                                      icon: UIApplicationShortcutIcon(systemImageName: "play.fill"),
                                      userInfo: ["titleId": app.titleId as NSString])
        }
    }

    private static func startMusicWhenJITIsReady() {
        if v3k_jit_preparing() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { startMusicWhenJITIsReady() }
        } else if window?.isHidden == false {
            MenuMusic.shared.libraryShown()
        }
    }

    static func hide() {
        BackgroundMotion.shared.setActive(false)
        // The game is about to start: the menu music fades out and stops
        MenuMusic.shared.libraryHidden()
        window?.isHidden = true
    }
}

// Called from C++ (ios_platform.mm) on the main thread
@_cdecl("v3k_ui_show")
public func v3kUIShow() {
    MainActor.assumeIsolated { LibraryHost.show() }
}

@_cdecl("v3k_ui_hide")
public func v3kUIHide() {
    MainActor.assumeIsolated { LibraryHost.hide() }
}
