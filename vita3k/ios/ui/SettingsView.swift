// Vita3K emulator project
// Copyright (C) 2026 Vita3K team
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: LibraryModel
    @Environment(\.dismiss) private var dismiss

    private let resolutions: [Double] = [0.5, 0.75, 1, 1.5, 2, 3, 4]
    private let anisotropy = [1, 2, 4, 8, 16]
    private let filters = ["Nearest", "Bilinear", "Bicubic", "FXAA", "FSR"]

    var body: some View {
        NavigationStack {
            Form {
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
                    Toggle("Turbo mode", isOn: binding(\.turboMode) { model.setBool("turbo-mode", $0) })
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
                    LabeledContent("Status", value: model.jitEnabled ? "Enabled" : "Not enabled")
                    Text("Enable JIT by launching Vita3K from StikDebug, or with “Launch with JIT” in LiveContainer.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
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
