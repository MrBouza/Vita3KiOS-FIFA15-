// Vita3K emulator project
// Copyright (C) 2026 Vita3K team
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import UniformTypeIdentifiers

/// Values of one game's settings (the global ones until the game gets its own)
struct GameSettings: Codable {
    var custom = false
    var resolutionMultiplier: Double = 1
    var anisotropicFiltering = 1
    var screenFilter = "Bilinear"
    var memoryMapping = true
    var highAccuracy = false
    var textureCache = true
    var cpuOpt = true
    var vSync = true
    var fpsHack = false
    var disableSurfaceSync = false
    var stretchDisplay = false
    var asyncShaders = true
    var shaderCache = true
}

struct GamePatch: Codable, Identifiable {
    let key: String
    let name: String
    let author: String
    let note: String
    let version: String
    let appVersion: String
    var enabled: Bool

    var id: String { key }
}

/// Everything about one game: its own settings, patches, shader cache and save data
struct GameSettingsView: View {
    let app: GameApp
    @EnvironmentObject var model: LibraryModel
    @Environment(\.dismiss) private var dismiss

    @State private var settings = GameSettings()
    @State private var patches: [GamePatch] = []
    @State private var patchesDownloaded = false
    @State private var downloadingPatches = false
    @State private var shaderCacheBytes: Double = 0
    @State private var message: String?
    @State private var exportedSave: URL?
    @State private var importingSave = false
    @State private var confirmDeleteSave = false
    @State private var confirmDeleteGame = false

    private let resolutions: [Double] = [0.5, 0.75, 1, 1.5, 2, 3, 4]
    private let anisotropy = [1, 2, 4, 8, 16]
    private let filters = ["Nearest", "Bilinear", "Bicubic", "FXAA", "FSR"]

    var body: some View {
        NavigationStack {
            Form {
                header
                settingsSection
                patchesSection
                storageSection
                Section {
                    Button(role: .destructive) { confirmDeleteGame = true } label: {
                        Label("Delete game", systemImage: "trash")
                    }
                }
            }
            .navigationTitle(app.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .onAppear(perform: load)
            .fileImporter(isPresented: $importingSave, allowedContentTypes: [.zip]) { result in
                guard case let .success(url) = result else { return }
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                var text: UnsafeMutablePointer<CChar>?
                _ = v3k_import_save_data(app.titleId, url.path, &text)
                message = takeString(text)
            }
            .sheet(item: Binding(get: { exportedSave.map(ShareItem.init) }, set: { if $0 == nil { exportedSave = nil } })) { item in
                ShareSheet(items: [item.url])
            }
            .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK", role: .cancel) {}
            }
            .alert("Delete the save data of \(app.title)?", isPresented: $confirmDeleteSave) {
                Button("Delete", role: .destructive) { model.deleteSaveData(app) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Export a backup first if you might want it back.")
            }
            .alert("Delete \(app.title)?", isPresented: $confirmDeleteGame) {
                Button("Delete", role: .destructive) {
                    model.delete(app)
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The game is removed from the device. Its save data is kept.")
            }
        }
    }

    // MARK: Sections

    private var header: some View {
        Section {
            HStack(spacing: 14) {
                Group {
                    if let icon = app.icon {
                        Image(uiImage: icon).resizable().scaledToFill()
                    } else {
                        Image(systemName: "gamecontroller.fill").font(.title).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(app.title).font(.headline)
                    Text("\(app.titleId) · v\(app.version)").font(.caption).foregroundStyle(.secondary)
                    Text(app.playTimeText).font(.caption).foregroundStyle(.secondary)
                }
            }
            Button {
                dismiss()
                model.launchRequested = app
            } label: {
                Label("Play", systemImage: "play.fill")
            }
        }
    }

    private var settingsSection: some View {
        Section {
            Toggle("Use settings for this game only", isOn: Binding(get: { settings.custom }, set: { on in
                if on {
                    // Writing any value creates the game's own settings, starting from the global ones
                    store("v-sync", settings.vSync ? "true" : "false")
                } else {
                    _ = v3k_reset_game_settings(app.titleId)
                }
                load()
                model.reload()
            }))

            if settings.custom {
                Picker("Resolution", selection: bind(\.resolutionMultiplier, "resolution-multiplier") { String($0) }) {
                    ForEach(resolutions, id: \.self) { Text(resolutionLabel($0)).tag($0) }
                }
                Picker("Screen filter", selection: bind(\.screenFilter, "screen-filter") { $0 }) {
                    ForEach(filters, id: \.self) { Text($0).tag($0) }
                }
                Picker("Anisotropic filtering", selection: bind(\.anisotropicFiltering, "anisotropic-filtering") { String($0) }) {
                    ForEach(anisotropy, id: \.self) { Text("\($0)×").tag($0) }
                }
                toggle("GPU memory mapping", \.memoryMapping, "memory-mapping", "Fixes wrong colours. Turn off only if this game breaks with it.")
                toggle("High accuracy", \.highAccuracy, "high-accuracy", "More accurate blending and effects, slower.")
                toggle("Texture cache", \.textureCache, "texture-cache", nil)
                toggle("Compile shaders in the background", \.asyncShaders, "async-shaders", "Less stutter; objects may pop in for a moment while their shaders compile.")
                toggle("Shader cache", \.shaderCache, "shader-cache", "Keeps compiled shaders so the next launch is smooth.")
                toggle("CPU optimisations", \.cpuOpt, "cpu-opt", nil)
                toggle("V-Sync", \.vSync, "v-sync", nil)
                toggle("FPS hack", \.fpsHack, "fps-hack", "Makes some 30 FPS games run at 60. Can speed up game logic.")
                toggle("Disable surface sync", \.disableSurfaceSync, "disable-surface-sync", "Faster in some games, breaks effects in others.")
                toggle("Stretch to screen", \.stretchDisplay, "stretch-display", nil)
            }
        } header: {
            Text("Settings")
        } footer: {
            Text(settings.custom
                 ? "These settings apply only to \(app.title), from its next launch."
                 : "\(app.title) uses the global settings.")
        }
    }

    private var patchesSection: some View {
        Section {
            if patches.isEmpty {
                Text(patchesDownloaded ? "No patches for this game yet." : "Download the community patch list to see fixes and enhancements for this game (60 FPS, resolution and bug fixes).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach($patches) { $patch in
                Toggle(isOn: Binding(get: { patch.enabled }, set: { on in
                    patch.enabled = on
                    _ = v3k_set_patch_enabled(patch.key, on)
                })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(patch.name)
                        let detail = [patch.author.isEmpty ? nil : "by \(patch.author)",
                                      patch.appVersion.isEmpty ? nil : "game v\(patch.appVersion)"].compactMap { $0 }.joined(separator: " · ")
                        if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary) }
                        if !patch.note.isEmpty { Text(patch.note).font(.caption2).foregroundStyle(.secondary) }
                    }
                }
            }
            Button {
                downloadPatches()
            } label: {
                HStack {
                    Label(patchesDownloaded ? "Update patch list" : "Download patch list", systemImage: "arrow.down.circle")
                    if downloadingPatches { Spacer(); ProgressView() }
                }
            }
            .disabled(downloadingPatches)
        } header: {
            Text("Patches")
        } footer: {
            Text("Patches come from github.com/Vita3K/vita3k-patches and apply the next time the game starts.")
        }
    }

    private var storageSection: some View {
        Section {
            LabeledContent("Shader cache", value: shaderCacheBytes > 0 ? ByteCountFormatter.string(fromByteCount: Int64(shaderCacheBytes), countStyle: .file) : "Empty")
            if shaderCacheBytes > 0 {
                Button("Delete shader cache", role: .destructive) {
                    _ = v3k_delete_shader_cache(app.titleId)
                    load()
                }
            }
            Button {
                var text: UnsafeMutablePointer<CChar>?
                if let path = takeString(v3k_export_save_data(app.titleId, &text)) {
                    _ = takeString(text)
                    exportedSave = URL(fileURLWithPath: path)
                } else {
                    message = takeString(text)
                }
            } label: {
                Label("Export save data", systemImage: "square.and.arrow.up")
            }
            Button {
                importingSave = true
            } label: {
                Label("Import save data (.zip)", systemImage: "square.and.arrow.down")
            }
            Button(role: .destructive) { confirmDeleteSave = true } label: {
                Label("Delete save data", systemImage: "externaldrive.badge.minus")
            }
        } header: {
            Text("Data")
        } footer: {
            Text("Deleting the shader cache only makes the next launch stutter while shaders compile again; do it if graphics break after an update. Exported saves are also kept in Files › Vita3KiOS › Save Backups.")
        }
    }

    // MARK: Helpers

    private func load() {
        if let json = takeString(v3k_game_settings_json(app.titleId)), let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(GameSettings.self, from: data) {
            settings = decoded
        }
        if let json = takeString(v3k_patches_json(app.titleId)), let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([GamePatch].self, from: data) {
            patches = decoded
        }
        patchesDownloaded = v3k_patches_downloaded()
        shaderCacheBytes = v3k_shader_cache_bytes(app.titleId)
    }

    private func downloadPatches() {
        downloadingPatches = true
        Task.detached {
            var text: UnsafeMutablePointer<CChar>?
            let ok = v3k_download_patches(&text)
            let summary = takeString(text)
            await MainActor.run {
                downloadingPatches = false
                load()
                if !ok || patches.isEmpty { message = summary }
            }
        }
    }

    private func store(_ key: String, _ value: String) {
        _ = v3k_set_game_setting(app.titleId, key, value)
    }

    private func bind<T>(_ keyPath: WritableKeyPath<GameSettings, T>, _ key: String, _ text: @escaping (T) -> String) -> Binding<T> {
        Binding(get: { settings[keyPath: keyPath] }, set: { value in
            settings[keyPath: keyPath] = value
            store(key, text(value))
        })
    }

    @ViewBuilder
    private func toggle(_ title: String, _ keyPath: WritableKeyPath<GameSettings, Bool>, _ key: String, _ detail: String?) -> some View {
        Toggle(isOn: bind(keyPath, key) { $0 ? "true" : "false" }) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    private func resolutionLabel(_ value: Double) -> String {
        let native = value == 1 ? " (native)" : ""
        return "\(value.formatted())× — \(Int(960 * value))×\(Int(544 * value))\(native)"
    }
}

// MARK: - Sharing

struct ShareItem: Identifiable {
    let url: URL
    var id: URL { url }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

extension GameApp {
    var playTimeText: String {
        guard playTime > 0 else { return "Not played yet" }
        let hours = playTime / 3600
        let minutes = (playTime % 3600) / 60
        if hours > 0 { return "Played \(hours) h \(minutes) min" }
        return "Played \(max(minutes, 1)) min"
    }
}
