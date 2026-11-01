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

private func takeString(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
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
    @Published var settings = EmulatorSettings()

    @Published var installProgress: InstallProgress?
    @Published var lastMessage: String?
    @Published var packageNeedingLicense: PendingImport?

    private var queue: [PendingImport] = []
    private var installing = false

    var hasFirmware: Bool { firmwareState & 2 != 0 }
    var hasFonts: Bool { firmwareState & 4 != 0 }
    var version: String { String(cString: v3k_version()) }
    var storagePath: String { String(cString: v3k_storage_path()) }

    func reload() {
        jitEnabled = v3k_is_jit_enabled()
        jitStatus = String(cString: v3k_jit_status_text())
        firmwareState = v3k_firmware_state()
        if let json = takeString(v3k_apps_json()), let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([GameApp].self, from: data) {
            apps = decoded.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }
        if let json = takeString(v3k_settings_json()), let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(EmulatorSettings.self, from: data) {
            settings = decoded
        }
    }

    func refresh() {
        v3k_refresh_apps()
        reload()
    }

    func launch(_ app: GameApp) {
        v3k_request_launch(app.titleId)
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
