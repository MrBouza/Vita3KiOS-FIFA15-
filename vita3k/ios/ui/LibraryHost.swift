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
        MenuMusic.shared.libraryShown()
        if firstShow {
            // Start preparing JIT once the library is on screen, so opening the app feels instant
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if v3k_jit_can_request() {
                    v3k_jit_request()
                    model.reload()
                }
            }
        }
    }

    private static var hasShown = false

    static func hide() {
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
