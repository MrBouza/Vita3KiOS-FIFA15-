// Vita3K emulator project
// Copyright (C) 2026 Vita3K team
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import UniformTypeIdentifiers

enum Theme {
    static let accent = Color(red: 0.25, green: 0.52, blue: 1.0)
    static let accent2 = Color(red: 0.55, green: 0.36, blue: 1.0)
    static let background = LinearGradient(
        colors: [Color(red: 0.05, green: 0.06, blue: 0.12), Color(red: 0.09, green: 0.07, blue: 0.20), .black],
        startPoint: .topLeading, endPoint: .bottomTrailing)
    static let card = Color.white.opacity(0.06)
    static let accentGradient = LinearGradient(colors: [accent, accent2], startPoint: .leading, endPoint: .trailing)
}

struct LibraryView: View {
    @EnvironmentObject var model: LibraryModel

    @State private var search = ""
    @State private var showingImporter = false
    @State private var importerTypes: [UTType] = [.item]
    @State private var showingSettings = false
    @State private var pendingLaunch: GameApp?
    @State private var pendingDelete: GameApp?
    @State private var zrifInput = ""

    private var filteredApps: [GameApp] {
        guard !search.isEmpty else { return model.apps }
        return model.apps.filter {
            $0.title.localizedCaseInsensitiveContains(search) || $0.titleId.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        StatusBar(jitEnabled: model.jitEnabled, hasFirmware: model.hasFirmware, hasFonts: model.hasFonts)

                        if !model.hasFirmware {
                            FirmwareCallout { openImporter([.item]) }
                        }

                        if model.apps.isEmpty {
                            EmptyLibrary(importFiles: { openImporter([.item]) }, importFolder: { openImporter([.folder]) })
                        } else {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 18)], spacing: 22) {
                                ForEach(filteredApps) { app in
                                    GameCard(app: app)
                                        .onTapGesture { requestLaunch(app) }
                                        .contextMenu {
                                            Button { requestLaunch(app) } label: { Label("Play", systemImage: "play.fill") }
                                            Button(role: .destructive) { pendingDelete = app } label: {
                                                Label("Delete", systemImage: "trash")
                                            }
                                        }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 40)
                }
                .refreshable { await MainActor.run { model.refresh() } }

                if let progress = model.installProgress {
                    InstallOverlay(progress: progress)
                }
            }
            .navigationTitle("Vita3K")
            .searchable(text: $search, prompt: "Search games")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { openImporter([.item]) } label: {
                            Label("Files (VPK, ZIP, PKG, PUP)", systemImage: "doc.badge.plus")
                        }
                        Button { openImporter([.folder]) } label: {
                            Label("Game folder", systemImage: "folder.badge.plus")
                        }
                    } label: {
                        Image(systemName: "plus.circle.fill").font(.title2).foregroundStyle(Theme.accentGradient)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingSettings = true } label: {
                        Image(systemName: "gearshape.fill").font(.title3)
                    }
                }
            }
            .fileImporter(isPresented: $showingImporter, allowedContentTypes: importerTypes, allowsMultipleSelection: true) { result in
                if case .success(let urls) = result {
                    model.enqueue(urls)
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView().environmentObject(model)
            }
            .alert("JIT is not ready", isPresented: Binding(get: { pendingLaunch != nil }, set: { if !$0 { pendingLaunch = nil } })) {
                Button("OK", role: .cancel) { pendingLaunch = nil }
            } message: {
                Text("\(model.jitStatus)\n\nClose Vita3K and launch it again with JIT enabled.")
            }
            .alert("Delete \(pendingDelete?.title ?? "")?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
                Button("Delete", role: .destructive) {
                    if let app = pendingDelete { model.delete(app) }
                    pendingDelete = nil
                }
                Button("Cancel", role: .cancel) { pendingDelete = nil }
            } message: {
                Text("The game is removed from Vita3K. Save data is kept.")
            }
            .alert("License needed", isPresented: Binding(get: { model.packageNeedingLicense != nil }, set: { _ in })) {
                TextField("zRIF", text: $zrifInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Install") {
                    model.provideLicense(zrifInput)
                    zrifInput = ""
                }
                Button("Install without", role: .cancel) {
                    model.provideLicense("")
                    zrifInput = ""
                }
            } message: {
                Text("\(model.packageNeedingLicense?.name ?? "This package") needs its zRIF license key. You can also put it in a .zrif file next to the .pkg.")
            }
            .alert(model.lastMessage ?? "", isPresented: Binding(get: { model.lastMessage != nil && model.packageNeedingLicense == nil }, set: { if !$0 { model.lastMessage = nil } })) {
                Button("OK", role: .cancel) { model.lastMessage = nil }
            }
        }
        .tint(Theme.accent)
    }

    private func openImporter(_ types: [UTType]) {
        importerTypes = types
        showingImporter = true
    }

    private func requestLaunch(_ app: GameApp) {
        model.reload()
        if model.jitEnabled {
            model.launch(app)
        } else {
            pendingLaunch = app
        }
    }
}

// MARK: - Pieces

struct GameCard: View {
    let app: GameApp

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Theme.card)
                if let icon = app.icon {
                    Image(uiImage: icon)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "gamecontroller.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(Theme.accentGradient)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(.white.opacity(0.08), lineWidth: 1))
            .shadow(color: Theme.accent.opacity(0.25), radius: 14, y: 6)

            Text(app.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .foregroundStyle(.white)
            HStack(spacing: 6) {
                Text(app.titleId).font(.caption2.monospaced())
                if !app.version.isEmpty {
                    Text("v\(app.version)").font(.caption2)
                }
            }
            .foregroundStyle(.white.opacity(0.5))
        }
        .contentShape(Rectangle())
    }
}

struct StatusBar: View {
    let jitEnabled: Bool
    let hasFirmware: Bool
    let hasFonts: Bool

    var body: some View {
        HStack(spacing: 10) {
            Pill(text: jitEnabled ? "JIT ready" : "JIT off", systemImage: "bolt.fill", good: jitEnabled)
            Pill(text: hasFirmware ? "Firmware" : "No firmware", systemImage: "cpu", good: hasFirmware)
            Pill(text: hasFonts ? "Fonts" : "No fonts", systemImage: "textformat", good: hasFonts)
            Spacer()
        }
        .padding(.top, 4)
    }
}

struct Pill: View {
    let text: String
    let systemImage: String
    let good: Bool

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill((good ? Color.green : Color.orange).opacity(0.18)))
            .foregroundStyle(good ? Color.green : Color.orange)
    }
}

struct FirmwareCallout: View {
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill").font(.title2).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text("Firmware required").font(.headline)
                Text("Most games need the PS Vita firmware (PSVUPDAT.PUP) and the font package (PSP2UPDAT.PUP). Download them from PlayStation's site, then import them here.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.7))
                Button("Import firmware", action: action)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.card))
    }
}

struct EmptyLibrary: View {
    let importFiles: () -> Void
    let importFolder: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 64))
                .foregroundStyle(Theme.accentGradient)
                .padding(.top, 40)
            Text("Your library is empty").font(.title2.bold())
            Text("Add games as .vpk, .zip, .pkg (with zRIF) or a dumped game folder.\nYou can also drop files into the Import folder of Vita3K in the Files app.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.65))
            HStack(spacing: 12) {
                Button(action: importFiles) { Label("Import files", systemImage: "doc.badge.plus") }
                    .buttonStyle(.borderedProminent)
                Button(action: importFolder) { Label("Import folder", systemImage: "folder.badge.plus") }
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }
}

struct InstallOverlay: View {
    let progress: InstallProgress

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView(value: min(max(progress.percent, 0), 100), total: 100)
                    .progressViewStyle(.linear)
                    .tint(Theme.accent)
                Text("Installing \(progress.name)")
                    .font(.headline)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text(progress.remaining > 0 ? "\(Int(progress.percent))% · \(progress.remaining) more queued" : "\(Int(progress.percent))%")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
            }
            .padding(24)
            .frame(maxWidth: 340)
            .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(.ultraThinMaterial))
        }
    }
}
