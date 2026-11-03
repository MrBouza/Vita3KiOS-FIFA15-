// Vita3K emulator project
// Copyright (C) 2026 Vita3K team
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import SwiftUI
import UIKit

struct GameApp: Codable, Identifiable, Hashable {
    let titleId: String
    let title: String
    let version: String
    let category: String
    let iconPath: String
    let path: String
    let lastPlayed: Int64
    let playTime: Int64
    let customConfig: Bool

    var id: String { titleId }

    var icon: UIImage? {
        iconPath.isEmpty ? nil : UIImage(contentsOfFile: iconPath)
    }
}

struct EmulatorSettings: Codable {
    var resolutionMultiplier: Double = 1
    var anisotropicFiltering: Int = 1
    var audioVolume: Int = 100
    var screenFilter: String = "Bilinear"
    var vSync: Bool = true
    var cpuOpt: Bool = true
    var ngsEnable: Bool = true
    var highAccuracy: Bool = false
    var stretchDisplay: Bool = false
    var performanceOverlay: Bool = false
    var textureCache: Bool = true
    var turboMode: Bool = false
    var pstvMode: Bool = false
    var memoryMapping: Bool = true
    var fpsHack: Bool = false
    var asyncShaders: Bool = true
}

struct StorageInfo: Codable {
    var path: String = ""
    var custom: Bool = false
    var freeBytes: UInt64 = 0
    var totalBytes: UInt64 = 0
    var note: String = ""

    var freeText: String {
        ByteCountFormatter.string(fromByteCount: Int64(freeBytes), countStyle: .file) + " free"
    }
}

struct CrashReport: Codable, Identifiable {
    let report: String
    let log: String
    var id: String { report }
}

/// One file or folder waiting to be installed
struct PendingImport: Identifiable {
    let id = UUID()
    let url: URL
    var zrif: String = ""

    var name: String { url.lastPathComponent }
    var kind: Int32 { v3k_install_kind(url.path) }
    var isPackage: Bool { kind == 3 }
}

struct InstallProgress {
    var name: String
    var percent: Double
    var remaining: Int
}

/// Boxes a progress handler so it can travel through the C callback's context pointer
private final class ProgressBox {
    let handler: (Double) -> Void
    init(_ handler: @escaping (Double) -> Void) { self.handler = handler }
}

func takeString(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
    guard let pointer else { return nil }
    defer { v3k_free_string(pointer) }
    return String(cString: pointer)
}

@MainActor
final class LibraryModel: ObservableObject {
    @Published var apps: [GameApp] = []
    @Published var firmwareState: Int32 = 0
    @Published var jitEnabled = false
    @Published var jitStatus = ""
    @Published var jitPreparing = false
    @Published var jitCanRequest = false
    @Published var jitProgress = 0
    @Published var jitTarget = 0
    @Published var settingUpJIT = false
    @Published var settings = EmulatorSettings()
    @Published var storage = StorageInfo()
    @Published var storageBusy = false

    @Published var installProgress: InstallProgress?
    @Published var lastMessage: String?
    @Published var packageNeedingLicense: PendingImport?
    /// Set to ask the library to launch a game (from the game settings sheet)
    @Published var launchRequested: GameApp?
    /// How the previous session ended, if it crashed (shown once)
    @Published var crashReport: CrashReport?

    private var queue: [PendingImport] = []
    private var installing = false

    var hasFirmware: Bool { firmwareState & 2 != 0 }
    var hasFonts: Bool { firmwareState & 4 != 0 }
    var version: String { String(cString: v3k_version()) }
    var storagePath: String { String(cString: v3k_storage_path()) }

    func reload() {
        jitEnabled = v3k_is_jit_enabled()
        jitPreparing = v3k_jit_preparing()
        jitCanRequest = v3k_jit_can_request()
        jitProgress = Int(v3k_jit_progress())
        jitTarget = Int(v3k_jit_target())
        jitStatus = takeString(v3k_jit_status_text()) ?? ""
        if jitPreparing && !settingUpJIT {
            // JIT is being set up in the background: look again shortly
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.reload() }
        }
        firmwareState = v3k_firmware_state()
        if let json = takeString(v3k_apps_json()), let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([GameApp].self, from: data) {
            apps = decoded.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }
        if let json = takeString(v3k_storage_info_json()), let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(StorageInfo.self, from: data) {
            storage = decoded
        }
        if let json = takeString(v3k_settings_json()), let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(EmulatorSettings.self, from: data) {
            settings = decoded
        }
    }

    /// Picks up the report of a crash in the previous session (once per launch)
    func checkForCrashReport() {
        // Wait until JIT setup is done: StikDebug pauses the app while it works, which made the
        // report hard to close
        if v3k_jit_preparing() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.checkForCrashReport() }
            return
        }
        if let json = takeString(v3k_take_crash_report()), let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(CrashReport.self, from: data) {
            crashReport = decoded
        }
    }

    func refresh() {
        v3k_refresh_apps()
        reload()
    }

    func launch(_ app: GameApp) {
        v3k_set_fast_cpu(UserDefaults.standard.bool(forKey: "v3k.fastCPU"))
        v3k_request_launch(app.titleId)
    }

    /// Asks the attached JIT script for executable memory, then reports whether JIT is ready.
    /// The debugger pauses the whole app while it works, so the overlay is shown first.
    func setUpJIT(completion: @escaping (Bool) -> Void) {
        settingUpJIT = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            v3k_jit_request()
            self.waitForJIT(completion: completion)
        }
    }

    private func waitForJIT(completion: @escaping (Bool) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if v3k_jit_preparing() {
                self.waitForJIT(completion: completion)
                return
            }
            self.settingUpJIT = false
            self.reload()
            completion(self.jitEnabled)
        }
    }

    func deleteSaveData(_ app: GameApp) {
        lastMessage = v3k_delete_save_data(app.titleId) ? "Save data of \(app.title) deleted." : "\(app.title) has no save data to delete."
    }

    // MARK: Storage location

    /// Uses a folder on the device or an external drive for games, saves and firmware. The folder is
    /// remembered as a bookmark so it can be reopened on the next launch.
    func chooseStorage(_ url: URL) {
        _ = url.startAccessingSecurityScopedResource() // kept open: games run from there
        guard let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) else {
            lastMessage = "Vita3K can't keep access to that folder. Try another location."
            return
        }
        let previous = UserDefaults.standard.data(forKey: "v3k.storageBookmark")
        UserDefaults.standard.set(bookmark, forKey: "v3k.storageBookmark")
        let path = url.path
        storageBusy = true
        Task.detached(priority: .userInitiated) {
            var message: UnsafeMutablePointer<CChar>?
            let ok = v3k_set_storage_folder(path, &message)
            let text = takeString(message) ?? ""
            await MainActor.run {
                if !ok { UserDefaults.standard.set(previous, forKey: "v3k.storageBookmark") }
                self.storageBusy = false
                self.lastMessage = text
                self.reload()
            }
        }
    }

    func useInternalStorage() {
        UserDefaults.standard.removeObject(forKey: "v3k.storageBookmark")
        storageBusy = true
        Task.detached(priority: .userInitiated) {
            var message: UnsafeMutablePointer<CChar>?
            _ = v3k_use_internal_storage(&message)
            let text = takeString(message) ?? ""
            await MainActor.run {
                self.storageBusy = false
                self.lastMessage = text
                self.reload()
            }
        }
    }

    func delete(_ app: GameApp) {
        if v3k_delete_app(app.titleId) {
            reload()
        }
    }

    // MARK: Importing

    func enqueue(_ urls: [URL]) {
        for url in urls {
            var item = PendingImport(url: url)
            if item.isPackage {
                let accessing = url.startAccessingSecurityScopedResource()
                if let stored = takeString(v3k_zrif_next_to(url.path)) {
                    item.zrif = stored
                }
                if accessing { url.stopAccessingSecurityScopedResource() }
            }
            queue.append(item)
        }
        processNext()
    }

    /// Called once the user entered (or skipped) the zRIF of the package being asked about
    func provideLicense(_ zrif: String) {
        guard var item = packageNeedingLicense else { return }
        packageNeedingLicense = nil
        item.zrif = zrif.trimmingCharacters(in: .whitespacesAndNewlines)
        install(item)
    }

    private func processNext() {
        guard !installing, packageNeedingLicense == nil, !queue.isEmpty else { return }
        let item = queue.removeFirst()
        if item.isPackage && item.zrif.isEmpty {
            packageNeedingLicense = item
            return
        }
        install(item)
    }

    private func install(_ item: PendingImport) {
        installing = true
        installProgress = InstallProgress(name: item.name, percent: 0, remaining: queue.count)

        let box = ProgressBox { [weak self] percent in
            Task { @MainActor in self?.installProgress?.percent = percent }
        }
        let context = Unmanaged.passRetained(box).toOpaque()
        let url = item.url
        let zrif = item.zrif

        Task.detached(priority: .userInitiated) {
            let accessing = url.startAccessingSecurityScopedResource()
            var message: UnsafeMutablePointer<CChar>?
            let ok = v3k_install(url.path, zrif, { ctx, percent in
                guard let ctx else { return }
                Unmanaged<ProgressBox>.fromOpaque(ctx).takeUnretainedValue().handler(Double(percent))
            }, context, &message)
            if accessing { url.stopAccessingSecurityScopedResource() }
            Unmanaged<ProgressBox>.fromOpaque(context).release()
            let text = takeString(message) ?? (ok ? "Installed." : "Installation failed.")

            await MainActor.run {
                self.installing = false
                self.installProgress = nil
                self.lastMessage = "\(item.name): \(text)"
                self.reload()
                self.processNext()
            }
        }
    }

    // MARK: Settings

    func setNumber(_ key: String, _ value: Double) {
        _ = v3k_set_setting_number(key, value)
    }

    func setBool(_ key: String, _ value: Bool) {
        _ = v3k_set_setting_bool(key, value)
    }

    func setString(_ key: String, _ value: String) {
        _ = v3k_set_setting_string(key, value)
    }
}
