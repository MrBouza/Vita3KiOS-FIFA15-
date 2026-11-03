// Vita3K emulator project
// Copyright (C) 2026 Vita3K team
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var model: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("v3k.theme") private var themeName = AppTheme.midnight.rawValue

    var body: some View {
        NavigationStack {
            Form {
                AppearanceSection()
                MusicSection()
                StorageSection()
                TouchControlsSection()
                EmulationSections()
                Section {
                    NavigationLink {
                        AllPatchesView()
                    } label: {
                        Label("Patches", systemImage: "bandage")
                    }
                } footer: {
                    Text("Cheats and mods are set per game: long-press a game › Game settings, patches & saves.")
                }
                JITSection()
                CreditsSection()
                AboutSection()
            }
            .alert(model.lastMessage ?? "", isPresented: Binding(get: { model.lastMessage != nil }, set: { if !$0 { model.lastMessage = nil } })) {
                Button("OK", role: .cancel) { model.lastMessage = nil }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .tint(AppTheme(rawValue: themeName)?.accent ?? Theme.accent)
    }
}

// MARK: - Appearance

struct AppearanceSection: View {
    @AppStorage("v3k.theme") private var themeName = AppTheme.midnight.rawValue
    @AppStorage("v3k.animatedBackground") private var animatedBackground = true

    var body: some View {
        Section("Appearance") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 12)], spacing: 12) {
                ForEach(AppTheme.allCases) { theme in
                    ThemeSwatch(theme: theme, selected: themeName == theme.rawValue) {
                        themeName = theme.rawValue
                    }
                }
            }
            .padding(.vertical, 4)
            Toggle(isOn: $animatedBackground) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Animated background")
                    Text("Moving light and particles for each theme, with a little tilt. Off when Reduce Motion is on.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct ThemeSwatch: View {
    let theme: AppTheme
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(theme.background)
                    .overlay(Circle().fill(theme.accentGradient).frame(width: 22, height: 22))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(selected ? theme.accent : Color.white.opacity(0.15), lineWidth: selected ? 2.5 : 1)
                    )
                    .frame(height: 54)
                Text(theme.name).font(.caption2).foregroundStyle(.primary)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Music

struct MusicSection: View {
    @AppStorage("v3k.musicEnabled") private var musicEnabled = true
    @AppStorage("v3k.musicVolume") private var musicVolume = 0.6
    @AppStorage("v3k.musicStyle") private var musicStyle = -1

    var body: some View {
        Section {
            Toggle("Menu music", isOn: $musicEnabled)
            if musicEnabled {
                Picker("Style", selection: $musicStyle) {
                    Text("Mix of everything").tag(-1)
                    ForEach(musicStyles.indices, id: \.self) { index in
                        Text(musicStyles[index].name).tag(index)
                    }
                }
                VStack(alignment: .leading) {
                    Text("Volume: \(Int(musicVolume * 100))%")
                    Slider(value: $musicVolume, in: 0...1, step: 0.05)
                }
                Button {
                    MenuMusic.shared.skip()
                } label: {
                    Label("Next song", systemImage: "forward.fill")
                }
            }
        } header: {
            Text("Music")
        } footer: {
            Text("Original songs composed on your device, a new one every time. Music stops when a game starts and stays quiet while another app is playing audio.")
        }
        .onChange(of: musicEnabled) { _, _ in MenuMusic.shared.settingsChanged() }
        .onChange(of: musicVolume) { _, _ in MenuMusic.shared.settingsChanged() }
        .onChange(of: musicStyle) { _, _ in
            MenuMusic.shared.settingsChanged()
            MenuMusic.shared.skip()
        }
    }
}

// MARK: - Storage

struct StorageSection: View {
    @EnvironmentObject var model: LibraryModel
    @State private var picking = false

    private var locationName: String {
        guard model.storage.custom else { return "This device" }
        let url = URL(fileURLWithPath: model.storage.path)
        return url.deletingLastPathComponent().lastPathComponent + "/" + url.lastPathComponent
    }

    var body: some View {
        Section {
            LabeledContent("Location", value: locationName)
            if model.storage.totalBytes > 0 {
                LabeledContent("Free", value: model.storage.freeText)
                LabeledContent("Used", value: model.storage.usedText)
            }
            if !model.storage.note.isEmpty {
                Label(model.storage.note, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            Button {
                picking = true
            } label: {
                Label("Choose folder or drive…", systemImage: "externaldrive.badge.plus")
            }
            .disabled(model.storageBusy)
            if model.storage.custom {
                Button {
                    model.useInternalStorage()
                } label: {
                    Label("Use this device's storage", systemImage: "iphone")
                }
                .disabled(model.storageBusy)
            }
            if model.storageBusy {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Moving storage…").foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Storage")
        } footer: {
            Text("Games, saves and firmware live here. Pick a folder on this device or on an external drive (USB-C SSD, thumb drive, microSD reader). Firmware is copied over automatically. You can also copy an existing Vita3K folder (with ux0 inside) onto the drive and pick it. Keep the drive connected while playing.")
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                model.chooseStorage(url)
            }
        }
    }
}

// MARK: - Touch controls

struct TouchControlsSection: View {
    @AppStorage("v3k.touchOpacity") private var touchOpacity = 0.6
    @AppStorage("v3k.touchScale") private var touchScale = 1.0
    @AppStorage("v3k.touchHideWithController") private var hideWithController = true
    @AppStorage("v3k.touchHaptics") private var touchHaptics = true
    @AppStorage("v3k.touchRearButton") private var rearButton = true
    @AppStorage("v3k.portraitMode") private var portraitMode = true
    @AppStorage("v3k.controllerTheme") private var controllerTheme = ControllerTheme.classic.rawValue
    @EnvironmentObject var model: LibraryModel
    @State private var layoutCustomized = TouchLayout.isCustomized

    var body: some View {
        Section {
            Picker("Theme", selection: $controllerTheme) {
                ForEach(ControllerTheme.allCases) { theme in
                    Text(theme.name).tag(theme.rawValue)
                }
            }
            VStack(alignment: .leading) {
                Text("Opacity: \(Int(touchOpacity * 100))%")
                Slider(value: $touchOpacity, in: 0.2...1, step: 0.05)
            }
            VStack(alignment: .leading) {
                Text("Size: \(Int(touchScale * 100))%")
                Slider(value: $touchScale, in: 0.7...1.4, step: 0.05)
            }
            Toggle("Hide when a controller is connected", isOn: $hideWithController)
            Toggle("Vibrate on press", isOn: $touchHaptics)
            Toggle(isOn: $portraitMode) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Portrait mode")
                    Text("Hold the phone upright to play with the game at the top and the controls below it. Landscape stays as it is; each has its own control layout.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Toggle(isOn: $rearButton) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Rear touchpad button")
                    Text("A button at the top of the screen that sends your touches to the Vita's rear touchpad, for games that use it. Also in the game menu.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Toggle(isOn: Binding(get: { model.settings.motion }, set: { value in
                model.settings.motion = value
                model.setBool("motion", value)
            })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Motion controls")
                    Text("Tilting the iPhone (or a controller with motion sensors) moves the Vita's gyroscope and accelerometer.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if layoutCustomized {
                Button("Reset control layout") {
                    TouchLayout.resetAll()
                    layoutCustomized = false
                }
            }
            NavigationLink {
                ControllerMappingView()
            } label: {
                Label("Button mapping", systemImage: "gamecontroller")
            }
        } header: {
            Text("Controls")
        } footer: {
            Text("Touch control changes apply the next time a game starts. In game, the ✕ at the top opens the game menu: screenshot, rear touchpad, edit control layout (drag and pinch to move and resize buttons) and quit. The eye button hides or shows the controls. With a controller, hold Select + Start, or press Home/PS, to open the menu.")
        }
    }
}

// MARK: - Emulation

struct EmulationSections: View {
    @EnvironmentObject var model: LibraryModel
    @AppStorage("v3k.fastCPU") private var fastCPU = false
    @State private var confirmClearShaders = false

    private let resolutions: [Double] = [0.5, 0.75, 1, 1.5, 2, 3, 4]
    private let anisotropy = [1, 2, 4, 8, 16]
    // No FSR: it needs a storage-capable RGBA8 swapchain, which Metal does not offer, so Vita3K
    // falls back to bilinear
    private let filters = ["Nearest", "Bilinear", "Bicubic", "FXAA"]

    var body: some View {
        Section {
            Picker("Internal resolution", selection: binding(\.resolutionMultiplier) { model.setNumber("resolution-multiplier", $0) }) {
                ForEach(resolutions, id: \.self) { value in
                    Text(label(for: value)).tag(value)
                }
            }
            Toggle(isOn: binding(\.fpsHack) { model.setBool("fps-hack", $0) }) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("60 FPS mode")
                    Text("Runs games that are locked to 30 FPS at 60. Works in many games; in some, the whole game speeds up 2×, so turn it off for those (or per game). A game's 60 FPS patch, if it has one, is the safer choice.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Resolution & frame rate")
        } footer: {
            Text("Above 1× (native, 960×544) games are rendered sharper but the GPU works harder: 1.5× or 2× suits most iPhones. For a softer, smoother picture at almost no cost, keep 1× and try the Bicubic or FXAA screen filter below. Applies from the next game launch; you can also set it per game.")
        }

        Section("Graphics") {
            Picker("Screen filter", selection: binding(\.screenFilter) { model.setString("screen-filter", $0) }) {
                ForEach(filters, id: \.self) { Text($0).tag($0) }
            }
            Picker("Anisotropic filtering", selection: binding(\.anisotropicFiltering) { model.setNumber("anisotropic-filtering", Double($0)) }) {
                ForEach(anisotropy, id: \.self) { Text("\($0)×").tag($0) }
            }
            Toggle("V-Sync", isOn: binding(\.vSync) { model.setBool("v-sync", $0) })
            Toggle("Texture cache", isOn: binding(\.textureCache) { model.setBool("texture-cache", $0) })
            Toggle("High accuracy", isOn: binding(\.highAccuracy) { model.setBool("high-accuracy", $0) })
            Toggle(isOn: binding(\.memoryMapping) { model.setBool("memory-mapping", $0) }) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("GPU memory mapping")
                    Text("Fixes wrong colours and stretched textures. Turn off only if a game breaks.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Toggle("Stretch to screen", isOn: binding(\.stretchDisplay) { model.setBool("stretch-display", $0) })
            Toggle(isOn: binding(\.surfaceSync) { model.setBool("surface-sync", $0) }) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Surface sync")
                    Text(model.settings.memoryMapping
                         ? "Lets games read back what they have drawn (bloom, reflections, some lighting). Off by default: it costs speed and can crash some games (Madden NFL 13). Better turned on per game, for the games that need it; Gravity Rush gets it automatically."
                         : "Needs GPU memory mapping, which is off: turn that on for surface sync to work.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }

        Section {
            Toggle(isOn: binding(\.asyncShaders) { model.setBool("async-shaders", $0) }) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Compile shaders in the background")
                    Text("Removes most stutter when new effects appear; objects can pop in for a moment.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Toggle(isOn: $fastCPU) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Fast CPU")
                    Text("Lets the CPU recompiler take floating-point shortcuts. Faster in CPU-heavy games; turn it off if a game shows physics or animation glitches.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Performance")
        } footer: {
            Text("Vita3KiOS also keeps game threads on the fast CPU cores, encodes GPU work in parallel and turns on iOS Game Mode automatically.")
        }

        Section {
            Toggle(isOn: binding(\.shaderCache) { model.setBool("shader-cache", $0) }) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Shader cache")
                    Text("Keeps compiled shaders between launches, so a game is smooth the second time.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Toggle("Show shader compile progress", isOn: binding(\.showCompileShaders) { model.setBool("show-compile-shaders", $0) })
            Toggle(isOn: binding(\.importTextures) { model.setBool("import-textures", $0) }) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Texture packs")
                    Text("Loads replacement textures from the Vita3K folder › textures › <title ID> (HD and translation packs).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Button("Clear all shader caches", role: .destructive) { confirmClearShaders = true }
        } header: {
            Text("Shaders & textures")
        } footer: {
            Text("Clearing the caches can fix games whose graphics broke after an update; each game compiles its shaders again the next time.")
        }
        .alert("Clear all shader caches?", isPresented: $confirmClearShaders) {
            Button("Clear", role: .destructive) {
                for app in model.apps { _ = v3k_delete_shader_cache(app.titleId) }
            }
            Button("Cancel", role: .cancel) {}
        }

        Section("System") {
            Picker("System language", selection: binding(\.sysLang) { model.setNumber("sys-lang", Double($0)) }) {
                ForEach(Self.languages, id: \.0) { Text($0.1).tag($0.0) }
            }
            Picker("Confirm button", selection: binding(\.sysButton) { model.setNumber("sys-button", Double($0)) }) {
                Text("✕ (Western games)").tag(1)
                Text("○ (Japanese games)").tag(0)
            }
            Toggle("CPU optimisations", isOn: binding(\.cpuOpt) { model.setBool("cpu-opt", $0) })
            Toggle("PS TV mode", isOn: binding(\.pstvMode) { model.setBool("pstv-mode", $0) })
            NavigationLink {
                PerformanceOverlaySettings()
            } label: {
                LabeledContent("Performance overlay", value: UserDefaults.standard.bool(forKey: "v3k.hud.enabled") ? "On" : "Off")
            }
        }

        Section("Game audio") {
            VStack(alignment: .leading) {
                Text("Volume: \(model.settings.audioVolume)%")
                Slider(value: Binding(
                    get: { Double(model.settings.audioVolume) },
                    set: { model.settings.audioVolume = Int($0) }
                ), in: 0...100, step: 5, onEditingChanged: { editing in
                    if !editing { model.setNumber("audio-volume", Double(model.settings.audioVolume)) }
                })
            }
            Toggle("NGS audio", isOn: binding(\.ngsEnable) { model.setBool("ngs-enable", $0) })
        }
    }

    private static let languages: [(Int, String)] = [
        (1, "English (US)"), (18, "English (UK)"), (0, "Japanese"), (2, "French"), (3, "Spanish"), (4, "German"),
        (5, "Italian"), (6, "Dutch"), (7, "Portuguese (Portugal)"), (17, "Portuguese (Brazil)"), (8, "Russian"),
        (9, "Korean"), (10, "Chinese (Traditional)"), (11, "Chinese (Simplified)"), (12, "Finnish"), (13, "Swedish"),
        (14, "Danish"), (15, "Norwegian"), (16, "Polish"), (19, "Turkish"),
    ]

    private func label(for value: Double) -> String {
        let native = "\(Int(960 * value))×\(Int(544 * value))"
        let factor = value == value.rounded() ? "\(Int(value))×" : "\(value)×"
        return "\(factor) (\(native))"
    }

    /// Binds a settings field and saves it to the core whenever it changes
    private func binding<T>(_ keyPath: WritableKeyPath<EmulatorSettings, T>, save: @escaping (T) -> Void) -> Binding<T> {
        Binding(
            get: { model.settings[keyPath: keyPath] },
            set: { newValue in
                model.settings[keyPath: keyPath] = newValue
                save(newValue)
            })
    }
}

// MARK: - JIT, credits, about

struct JITSection: View {
    @EnvironmentObject var model: LibraryModel

    var body: some View {
        Section("JIT") {
            LabeledContent("Status", value: model.jitEnabled ? "Ready" : "Not ready")
            Text(model.jitStatus)
                .font(.footnote)
            Text("Launch Vita3K from StikDebug, or with “Launch with JIT” in LiveContainer. On iOS 26 with an A15 or newer chip, also choose StikDebug's universal.js as Vita3K's JIT script.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

struct CreditsSection: View {
    var body: some View {
        Section {
            CreditRow(name: "Vita3K", detail: "The PS Vita emulator this app is built on, by the Vita3K team and contributors.", url: "https://github.com/Vita3K/Vita3K")
            CreditRow(name: "Tsubomi by 125hz", detail: "iOS 26 JIT (dynarmic/oaknut patch and region pool), guest memory pre-reservation, audio session and display fixes.", url: "https://github.com/125hz/Tsubomi")
            CreditRow(name: "dynarmic & oaknut", detail: "ARM recompiler and arm64 assembler, by merryhime and contributors.", url: "https://github.com/merryhime/dynarmic")
            CreditRow(name: "MoltenVK", detail: "Vulkan on Apple's Metal, by the Khronos Group.", url: "https://github.com/KhronosGroup/MoltenVK")
            CreditRow(name: "SDL", detail: "Windowing, input and audio.", url: "https://github.com/libsdl-org/SDL")
        } header: {
            Text("Credits")
        } footer: {
            Text("Vita3KiOS is free software under the GNU GPL v2 or later.")
        }
    }
}

struct AboutSection: View {
    @EnvironmentObject var model: LibraryModel

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let commit = info?["V3KCommit"] as? String
        return "\(version) (\(build)\(commit.map { ", " + $0 } ?? ""))"
    }

    private var previousLog: String {
        URL(fileURLWithPath: String(cString: v3k_log_path())).deletingLastPathComponent()
            .appendingPathComponent("vita3k-previous.log").path
    }

    var body: some View {
        Section("About") {
            LabeledContent("Version", value: appVersion)
            LabeledContent("Core", value: model.version)
            ShareLink(item: URL(fileURLWithPath: String(cString: v3k_log_path()))) {
                Label("Share log", systemImage: "square.and.arrow.up")
            }
            if FileManager.default.fileExists(atPath: previousLog) {
                ShareLink(item: URL(fileURLWithPath: previousLog)) {
                    Label("Share previous session's log", systemImage: "clock.arrow.circlepath")
                }
            }
            Link(destination: URL(string: "https://discord.gg/pZyQDPHKF")!) {
                Label("Join the Discord", systemImage: "bubble.left.and.bubble.right")
            }
            Text("Attach the log when reporting a problem, on the Discord for example. It's also in the app's folder in the Files app.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

struct CreditRow: View {
    let name: String
    let detail: String
    let url: String

    var body: some View {
        Link(destination: URL(string: url)!) {
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Button mapping

/// Chooses which controller button triggers each Vita button. Applies to physical controllers; the
/// on-screen buttons follow it automatically so their labels stay right.
struct ControllerMappingView: View {
    private struct Slot: Identifiable {
        let id: Int32 // SDL_GamepadButton number of the slot
        let name: String
    }

    private let slots: [Slot] = [
        Slot(id: 0, name: "✕ Cross"), Slot(id: 1, name: "○ Circle"), Slot(id: 2, name: "□ Square"), Slot(id: 3, name: "△ Triangle"),
        Slot(id: 9, name: "L"), Slot(id: 10, name: "R"), Slot(id: 4, name: "Select"), Slot(id: 6, name: "Start"),
        Slot(id: 5, name: "PS button"), Slot(id: 7, name: "L3 (PS TV)"), Slot(id: 8, name: "R3 (PS TV)"),
        Slot(id: 11, name: "D-pad up"), Slot(id: 12, name: "D-pad down"), Slot(id: 13, name: "D-pad left"), Slot(id: 14, name: "D-pad right"),
    ]

    private let physicalNames: [Int32: String] = [
        0: "Bottom face (A / ✕)", 1: "Right face (B / ○)", 2: "Left face (X / □)", 3: "Top face (Y / △)",
        4: "View / Select / Share", 5: "Home / PS", 6: "Menu / Start / Options",
        7: "Left stick press", 8: "Right stick press", 9: "Left shoulder", 10: "Right shoulder",
        11: "D-pad up", 12: "D-pad down", 13: "D-pad left", 14: "D-pad right",
    ]

    @State private var binds: [Int32] = Array(0..<15)

    var body: some View {
        Form {
            Section {
                ForEach(slots) { slot in
                    Picker(slot.name, selection: Binding(
                        get: { binds[Int(slot.id)] },
                        set: { newValue in
                            binds[Int(slot.id)] = newValue
                            _ = v3k_set_controller_bind(slot.id, newValue)
                        })) {
                        ForEach(0..<15, id: \.self) { physical in
                            Text(physicalNames[Int32(physical)] ?? "Button \(physical)").tag(Int32(physical))
                        }
                    }
                }
            } footer: {
                Text("Pick the controller button for each PS Vita button. The on-screen controls follow this mapping automatically.")
            }

            Section {
                Button("Swap ✕ and ○ (Japanese style)") {
                    let cross = binds[0]
                    binds[0] = binds[1]
                    binds[1] = cross
                    _ = v3k_set_controller_bind(0, binds[0])
                    _ = v3k_set_controller_bind(1, binds[1])
                }
                Button("Reset to default", role: .destructive) {
                    v3k_reset_controller_binds()
                    load()
                }
            }
        }
        .navigationTitle("Button mapping")
        .onAppear(perform: load)
    }

    private func load() {
        guard let pointer = v3k_controller_binds_json() else { return }
        let json = String(cString: pointer)
        v3k_free_string(pointer)
        if let data = json.data(using: .utf8), let decoded = try? JSONDecoder().decode([Int32].self, from: data), decoded.count >= 15 {
            binds = decoded
        }
    }
}

// MARK: - Performance overlay

struct PerformanceOverlaySettings: View {
    @AppStorage("v3k.hud.enabled") private var enabled = false
    @AppStorage("v3k.hud.position") private var position = 0
    @AppStorage("v3k.hud.size") private var size = 1
    @AppStorage("v3k.hud.opacity") private var opacity = 0.35
    @State private var refresh = false

    var body: some View {
        Form {
            Section {
                Toggle("Show performance overlay", isOn: $enabled)
            } footer: {
                Text("A small see-through panel over the game. It applies the next time a game starts.")
            }
            if enabled {
                Section("Show") {
                    ForEach(HUDSettings.items) { item in
                        Toggle(isOn: Binding(
                            get: { _ = refresh; return HUDSettings.isOn(item.key) },
                            set: { UserDefaults.standard.set($0, forKey: "v3k.hud.\(item.key)"); refresh.toggle() }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                Text(item.detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section {
                    Picker("Position", selection: $position) {
                        ForEach(HUDSettings.positions.indices, id: \.self) { Text(HUDSettings.positions[$0]).tag($0) }
                    }
                    Picker("Text size", selection: $size) {
                        ForEach(HUDSettings.sizes.indices, id: \.self) { Text(HUDSettings.sizes[$0]).tag($0) }
                    }
                    VStack(alignment: .leading) {
                        Text("Background: \(Int(opacity * 100))%")
                        Slider(value: $opacity, in: 0...0.8, step: 0.05)
                    }
                } header: {
                    Text("Layout")
                } footer: {
                    Text("Thermal state is what iOS reports (it doesn't give apps a temperature). When it reaches Serious, iOS slows the chip down, and frame rates drop.")
                }
            }
        }
        .navigationTitle("Performance overlay")
    }
}
