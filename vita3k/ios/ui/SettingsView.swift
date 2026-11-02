// Vita3K emulator project
// Copyright (C) 2026 Vita3K team
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var model: LibraryModel
    @Environment(\.dismiss) private var dismiss

    @State private var pickingStorage = false
    @AppStorage("v3k.touchOpacity") private var touchOpacity = 0.6
    @AppStorage("v3k.touchScale") private var touchScale = 1.0
    @AppStorage("v3k.touchHideWithController") private var hideWithController = true

    private let resolutions: [Double] = [0.5, 0.75, 1, 1.5, 2, 3, 4]
    private let anisotropy = [1, 2, 4, 8, 16]
    private let filters = ["Nearest", "Bilinear", "Bicubic", "FXAA", "FSR"]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Location", value: model.storage.custom ? URL(fileURLWithPath: model.storage.path).deletingLastPathComponent().lastPathComponent + "/" + URL(fileURLWithPath: model.storage.path).lastPathComponent : "This device")
                    if model.storage.totalBytes > 0 {
                        LabeledContent("Space", value: model.storage.freeText)
                    }
                    if !model.storage.note.isEmpty {
                        Label(model.storage.note, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                    Button {
                        pickingStorage = true
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
                    Text("Games, saves and firmware live here. Pick a folder on this device or on an external drive (USB-C SSD, thumb drive, microSD reader) in the Files picker. Firmware is copied over automatically; install games again or copy your existing Vita3K folder (with ux0 inside) onto the drive and pick it. Keep the drive connected while playing.")
                }

                Section {
                    VStack(alignment: .leading) {
                        Text("Opacity: \(Int(touchOpacity * 100))%")
                        Slider(value: $touchOpacity, in: 0.2...1, step: 0.05)
                    }
                    VStack(alignment: .leading) {
                        Text("Size: \(Int(touchScale * 100))%")
                        Slider(value: $touchScale, in: 0.7...1.4, step: 0.05)
                    }
                    Toggle("Hide when a controller is connected", isOn: $hideWithController)
                } header: {
                    Text("Touch controls")
                } footer: {
                    Text("Applies the next time a game starts. In game, the eye button hides or shows the controls and ✕ quits.")
                }

                Section("Graphics") {
                    Picker("Resolution", selection: binding(\.resolutionMultiplier) { model.setNumber("resolution-multiplier", $0) }) {
                        ForEach(resolutions, id: \.self) { value in
                            Text(label(for: value)).tag(value)
                        }
                    }
                    Picker("Screen filter", selection: binding(\.screenFilter) { model.setString("screen-filter", $0) }) {
                        ForEach(filters, id: \.self) { Text($0).tag($0) }
                    }
                    Picker("Anisotropic filtering", selection: binding(\.anisotropicFiltering) { model.setNumber("anisotropic-filtering", Double($0)) }) {
                        ForEach(anisotropy, id: \.self) { Text("\($0)×").tag($0) }
                    }
                    Toggle("V-Sync", isOn: binding(\.vSync) { model.setBool("v-sync", $0) })
                    Toggle("Texture cache", isOn: binding(\.textureCache) { model.setBool("texture-cache", $0) })
                    Toggle("High accuracy", isOn: binding(\.highAccuracy) { model.setBool("high-accuracy", $0) })
                    Toggle("Stretch to screen", isOn: binding(\.stretchDisplay) { model.setBool("stretch-display", $0) })
                }

                Section("System") {
                    Toggle("CPU optimisations", isOn: binding(\.cpuOpt) { model.setBool("cpu-opt", $0) })
                    Toggle("PS TV mode", isOn: binding(\.pstvMode) { model.setBool("pstv-mode", $0) })
                    Toggle("Performance overlay", isOn: binding(\.performanceOverlay) { model.setBool("performance-overlay", $0) })
                }

                Section("Audio") {
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

                Section("JIT") {
                    LabeledContent("Status", value: model.jitEnabled ? "Ready" : "Not ready")
                    Text(model.jitStatus)
                        .font(.footnote)
                    Text("Launch Vita3K from StikDebug, or with “Launch with JIT” in LiveContainer. On iOS 26 with an A15 or newer chip, also choose StikDebug's universal.js as Vita3K's JIT script.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

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

                Section("About") {
                    LabeledContent("Version", value: model.version)
                    LabeledContent("Storage", value: model.storagePath)
                        .lineLimit(2)
                    Text("Logs are saved as vita3k.log in the app's folder in the Files app.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .fileImporter(isPresented: $pickingStorage, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result {
                    model.chooseStorage(url)
                }
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
    }

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
