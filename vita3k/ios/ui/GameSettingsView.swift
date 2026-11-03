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
    let versionMatches: Bool

    var id: String { key }
}

struct GameCheat: Codable, Identifiable {
    let key: String
    let name: String
    let author: String
    let file: String
    let gameVersion: String
    let supported: Bool
    var enabled: Bool
    let versionMatches: Bool

    var id: String { key }
}

struct GameContent: Codable {
    var update = ""
    var updateBytes: Double = 0
    var dlc = 0
    var dlcBytes: Double = 0
}

struct ModInfo: Codable {
    var path = ""
    var files = 0
    var bytes: Double = 0
    var enabled = true
}

/// What the shared zip picker is choosing a file for
private enum ZipImport: Identifiable {
    case save, mod
    var id: Int { self == .save ? 0 : 1 }
}

/// Everything about one game: its own settings, patches, shader cache and save data
struct GameSettingsView: View {
    let app: GameApp
    @EnvironmentObject var model: LibraryModel
    @Environment(\.dismiss) private var dismiss

    @State private var preciseMath = false
    @State private var showingShortcutHelp = false
    @State private var settings = GameSettings()
    @State private var patches: [GamePatch] = []
    @State private var patchesDownloaded = false
    @State private var downloadingPatches = false
    @State private var shaderCacheBytes: Double = 0
    @State private var message: String?
    @State private var exportedSave: URL?
    @State private var zipImport: ZipImport?
    @State private var cheats: [GameCheat] = []
    @State private var cheatsDownloaded = false
    @State private var showUnsupportedCheats = false
    @State private var mod = ModInfo()
    @State private var content = GameContent()
    @State private var confirmDeleteMods = false
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
                contentSection
                patchesSection
                cheatsSection
                modsSection
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
            .fileImporter(isPresented: Binding(get: { zipImport != nil }, set: { if !$0 { zipImport = nil } }), allowedContentTypes: [.zip]) { result in
                let kind = zipImport
                zipImport = nil
                guard case let .success(url) = result, let kind else { return }
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                var text: UnsafeMutablePointer<CChar>?
                switch kind {
                case .save: _ = v3k_import_save_data(app.titleId, url.path, &text)
                case .mod: _ = v3k_import_mod(app.titleId, url.path, &text)
                }
                message = takeString(text)
                load()
            }
            .alert("Delete the mods of \(app.title)?", isPresented: $confirmDeleteMods) {
                Button("Delete", role: .destructive) {
                    _ = v3k_delete_mods(app.titleId)
                    load()
                }
                Button("Cancel", role: .cancel) {}
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
            Button {
                UIPasteboard.general.string = "vita3k://launch/\(app.titleId)"
                showingShortcutHelp = true
            } label: {
                Label("Add to Home Screen…", systemImage: "plus.app")
            }
        }
        .alert("Launch link copied", isPresented: $showingShortcutHelp) {
            Button("Open Shortcuts") {
                if let url = URL(string: "shortcuts://create-shortcut") { UIApplication.shared.open(url) }
            }
            Button("Done", role: .cancel) {}
        } message: {
            Text("vita3k://launch/\(app.titleId) is on the clipboard. In Shortcuts, add the Open URLs action, paste the link, then tap Share › Add to Home Screen and pick the game's icon. Vita3K also lists your recent games when you long-press its icon.")
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
                Toggle(isOn: Binding(get: { !settings.disableSurfaceSync }, set: { on in
                    settings.disableSurfaceSync = !on
                    store("disable-surface-sync", on ? "false" : "true")
                })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Surface sync")
                        Text(settings.memoryMapping
                             ? "Lets the game read back what it has drawn (bloom, reflections, lighting). Slower when on."
                             : "Needs GPU memory mapping (above).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                toggle("Stretch to screen", \.stretchDisplay, "stretch-display", nil)
            }
            Toggle(isOn: Binding(get: { preciseMath }, set: { on in
                preciseMath = on
                UserDefaults.standard.set(on, forKey: "v3k.preciseMath.\(app.titleId)")
            })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Precise shader math")
                    Text("Turns off Metal's fast math for this game. Try it when lighting or effects look too bright or flicker; a little slower.")
                        .font(.caption).foregroundStyle(.secondary)
                }
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
            if !patchesDownloaded {
                Text("Download the community patches and cheats to see what's available for this game.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if patches.isEmpty {
                Text("There are no community patches for \(app.title) (\(app.titleId)). Settings › Patches lists every game that has one.")
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
                        Text(patch.appVersion.isEmpty ? "Any game version" : "For game version \(patch.appVersion)")
                            .font(.caption)
                            .foregroundStyle(patch.versionMatches ? Color.secondary : Color.orange)
                        if !patch.versionMatches {
                            Text("You have version \(app.version), so this patch won't apply. Install the matching game update.")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                        if !patch.note.isEmpty { Text(patch.note).font(.caption2).foregroundStyle(.secondary) }
                    }
                }
            }
            downloadButton
        } header: {
            Text("Patches")
        } footer: {
            Text("Patches come from github.com/Vita3K/vita3k-patches and apply the next time the game starts.")
        }
    }

    private var contentSection: some View {
        Section {
            LabeledContent("Update", value: content.update.isEmpty ? "None" : "v\(content.update) · \(size(content.updateBytes))")
            LabeledContent("DLC", value: content.dlc == 0 ? "None" : "\(content.dlc) · \(size(content.dlcBytes))")
            if !content.update.isEmpty {
                Button("Delete update", role: .destructive) {
                    _ = v3k_delete_game_content(app.titleId, true)
                    load()
                }
            }
            if content.dlc > 0 {
                Button("Delete all DLC", role: .destructive) {
                    _ = v3k_delete_game_content(app.titleId, false)
                    load()
                }
            }
        } header: {
            Text("Updates & DLC")
        } footer: {
            Text("Install updates and DLC like games: + › Files, as .pkg, .vpk, .zip or a dumped folder. Updates don't need a zRIF: they use the game's license.")
        }
    }

    private func size(_ bytes: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private var downloadButton: some View {
        Button {
            downloadPatches()
        } label: {
            HStack {
                Label(patchesDownloaded ? "Update patches & cheats" : "Download patches & cheats", systemImage: "arrow.down.circle")
                if downloadingPatches { Spacer(); ProgressView() }
            }
        }
        .disabled(downloadingPatches)
    }

    private var cheatsSection: some View {
        Section {
            let shown = cheats.filter { $0.supported || showUnsupportedCheats }
            if !cheatsDownloaded {
                Text("Download the community patches and cheats (above) to see cheats for this game.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if cheats.isEmpty {
                Text("There are no cheats for \(app.title) (\(app.titleId)) in the database. You can add your own VitaCheat .psv file to Files › Vita3KiOS › patch › cheats.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if let version = cheats.first(where: { !$0.versionMatches })?.gameVersion {
                Text("These cheats were written for game version \(version); you have \(app.version). They may do nothing, or the wrong thing.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            ForEach(shown) { cheat in
                Toggle(isOn: Binding(get: { cheat.enabled }, set: { on in
                    if let index = cheats.firstIndex(where: { $0.key == cheat.key }) { cheats[index].enabled = on }
                    _ = v3k_set_cheat_enabled(app.titleId, cheat.key, on)
                })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(cheat.name)
                        if !cheat.supported {
                            Text("Uses a code type Vita3KiOS can't run yet").font(.caption2).foregroundStyle(.orange)
                        } else if !cheat.author.isEmpty {
                            Text("by \(cheat.author)").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(!cheat.supported)
            }
            let unsupported = cheats.filter { !$0.supported }.count
            if unsupported > 0 {
                Toggle("Show \(unsupported) unsupported cheat\(unsupported == 1 ? "" : "s")", isOn: $showUnsupportedCheats)
                    .font(.footnote)
            }
        } header: {
            Text(cheats.isEmpty ? "Cheats" : "Cheats (\(cheats.filter(\.supported).count))")
        } footer: {
            Text("Cheats run while the game plays and apply the next time it starts. Back up your save first: a wrong cheat can corrupt it.")
        }
    }

    private var modsSection: some View {
        Section {
            if mod.files > 0 {
                Toggle(isOn: Binding(get: { mod.enabled }, set: { on in
                    _ = v3k_set_mods_enabled(app.titleId, on)
                    load()
                })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Use mods")
                        Text("\(mod.files) file\(mod.files == 1 ? "" : "s"), \(ByteCountFormatter.string(fromByteCount: Int64(mod.bytes), countStyle: .file))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Button {
                zipImport = .mod
            } label: {
                Label("Install mod (.zip)", systemImage: "puzzlepiece.extension")
            }
            if mod.files > 0 {
                Button(role: .destructive) { confirmDeleteMods = true } label: {
                    Label("Delete mods", systemImage: "trash")
                }
            }
        } header: {
            Text("Mods")
        } footer: {
            Text("Files of a mod replace the game's files, like rePatch on a PS Vita: Vita rePatch mods work as they are. You can also copy files into Files › Vita3KiOS › vita › ux0 › rePatch › \(app.titleId). Changes apply the next time the game starts.")
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
                zipImport = .save
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
        preciseMath = UserDefaults.standard.bool(forKey: "v3k.preciseMath.\(app.titleId)")
        if let json = takeString(v3k_game_settings_json(app.titleId)), let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(GameSettings.self, from: data) {
            settings = decoded
        }
        if let json = takeString(v3k_patches_json(app.titleId)), let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([GamePatch].self, from: data) {
            patches = decoded
        }
        patchesDownloaded = v3k_patches_downloaded()
        cheatsDownloaded = v3k_cheats_downloaded()
        if let json = takeString(v3k_cheats_json(app.titleId)), let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([GameCheat].self, from: data) {
            cheats = decoded
        }
        if let json = takeString(v3k_game_content_json(app.titleId)), let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(GameContent.self, from: data) {
            content = decoded
        }
        if let json = takeString(v3k_mod_info_json(app.titleId)), let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(ModInfo.self, from: data) {
            mod = decoded
        }
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
                message = summary
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

// MARK: - Every patch

struct PatchGame: Codable, Identifiable {
    let title: String
    let titleIds: [String]
    let installedTitleId: String
    let installedVersion: String
    var patches: [GamePatch]

    var id: String { title }
    var installed: Bool { !installedTitleId.isEmpty }
}

/// Every community patch, one section per game, with the games you have first
struct AllPatchesView: View {
    @State private var games: [PatchGame] = []
    @State private var downloaded = false
    @State private var downloading = false
    @State private var onlyInstalled = false
    @State private var search = ""
    @State private var message: String?

    private var shown: [PatchGame] {
        games.filter { game in
            (!onlyInstalled || game.installed)
                && (search.isEmpty || game.title.localizedCaseInsensitiveContains(search)
                    || game.titleIds.contains { $0.localizedCaseInsensitiveContains(search) })
        }
        .sorted { ($0.installed ? 0 : 1, $0.title) < ($1.installed ? 0 : 1, $1.title) }
    }

    var body: some View {
        List {
            Section {
                Button {
                    download()
                } label: {
                    HStack {
                        Label(downloaded ? "Update patches & cheats" : "Download patches & cheats", systemImage: "arrow.down.circle")
                        if downloading { Spacer(); ProgressView() }
                    }
                }
                .disabled(downloading)
                if downloaded {
                    Toggle("Only games I have", isOn: $onlyInstalled)
                    let total = games.reduce(0) { $0 + $1.patches.count }
                    let installed = games.filter(\.installed).count
                    Text("\(total) patches for \(games.count) games. You have \(installed) of these games.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("A patch applies only to the game version it was made for. Turn patches on here or from a game's settings; they apply the next time the game starts.")
            }

            ForEach($games) { $game in
                if shown.contains(where: { $0.id == game.id }) {
                    Section {
                        ForEach($game.patches) { $patch in
                            Toggle(isOn: Binding(get: { patch.enabled }, set: { on in
                                patch.enabled = on
                                _ = v3k_set_patch_enabled(patch.key, on)
                            })) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(patch.name)
                                    Text(patch.appVersion.isEmpty ? "Any game version" : "For game version \(patch.appVersion)")
                                        .font(.caption)
                                        .foregroundStyle(!game.installed || patch.versionMatches ? Color.secondary : Color.orange)
                                    if game.installed && !patch.versionMatches {
                                        Text("You have version \(game.installedVersion): it won't apply")
                                            .font(.caption2)
                                            .foregroundStyle(.orange)
                                    }
                                }
                            }
                        }
                    } header: {
                        HStack {
                            Text(game.title)
                            Spacer()
                            if game.installed {
                                Text("INSTALLED").font(.caption2.weight(.bold)).foregroundStyle(.green)
                            }
                        }
                    } footer: {
                        Text(game.titleIds.joined(separator: " · "))
                    }
                }
            }
        }
        .searchable(text: $search, prompt: "Game or title ID")
        .navigationTitle("Patches")
        .onAppear(perform: load)
        .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }

    private func load() {
        downloaded = v3k_patches_downloaded()
        if let json = takeString(v3k_all_patches_json()), let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([PatchGame].self, from: data) {
            games = decoded
        }
    }

    private func download() {
        downloading = true
        Task.detached {
            var text: UnsafeMutablePointer<CChar>?
            _ = v3k_download_patches(&text)
            let summary = takeString(text)
            await MainActor.run {
                downloading = false
                load()
                message = summary
            }
        }
    }
}
