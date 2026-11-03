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
        let firstShow = !hasShown
        hasShown = true
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
