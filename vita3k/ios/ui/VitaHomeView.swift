// Vita3K emulator project
// Copyright (C) 2026 Vita3K team
// SPDX-License-Identifier: GPL-2.0-or-later

import AVFoundation
import SwiftUI
import UIKit

/// Assets of the installed PS Vita firmware (vs0 / pd0 partitions) and of installed themes (ux0/theme),
/// used to dress the home screen like the real thing.
enum VitaFirmware {
    private static var cache: [String: UIImage] = [:]

    static var root: String {
        guard let cPath = v3k_pref_path() else { return "" }
        defer { v3k_free_string(cPath) }
        return String(cString: cPath)
    }

    private static func full(_ relative: String) -> String {
        (root as NSString).appendingPathComponent(relative)
    }

    /// Image at a path below the Vita folder, nil when it doesn't exist
    static func image(atPath relative: String) -> UIImage? {
        if let cached = cache[relative] { return cached }
        guard let image = UIImage(contentsOfFile: full(relative)) else { return nil }
        cache[relative] = image
        return image
    }

    static func image(_ relativeToVs0: String) -> UIImage? { image(atPath: "vs0/" + relativeToVs0) }

    /// Wallpapers of the firmware's default theme
    static var defaultWallpapers: [String] {
        ["NPXS10002", "NPXS10006", "NPXS10013", "NPXS10018", "NPXS10098"]
            .map { "vs0/app/\($0)/sce_sys/pic0.png" }
            .filter { FileManager.default.fileExists(atPath: full($0)) }
    }

    /// The start (lock) screen picture
    static var lockScreen: UIImage? { image("data/internal/keylock/keylock.png") }

    static let defaultMusicPath = "pd0/data/systembgm/home.at9"

    static func exists(_ relative: String) -> Bool { FileManager.default.fileExists(atPath: full(relative)) }
    static func absolute(_ relative: String) -> String { full(relative) }
}

/// A theme for the home screen: the firmware's default one, or one installed in ux0/theme
struct VitaTheme: Identifiable, Hashable {
    let id: String
    let name: String
    /// Paths below the Vita folder, one per page (the last ones repeat)
    let wallpapers: [String]
    /// Home music below the Vita folder (.at9), nil when the theme has none
    let music: String?
    let fontColor: Color

    static let defaultId = "default"

    static var builtIn: VitaTheme {
        VitaTheme(id: defaultId, name: "Default", wallpapers: VitaFirmware.defaultWallpapers,
                  music: VitaFirmware.exists(VitaFirmware.defaultMusicPath) ? VitaFirmware.defaultMusicPath : nil, fontColor: .white)
    }

    static func installed() -> [VitaTheme] {
        let folder = (VitaFirmware.root as NSString).appendingPathComponent("ux0/theme")
        let ids = ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).sorted()
        return [builtIn] + ids.compactMap { load(id: $0) }
    }

    static func current() -> VitaTheme {
        let id = UserDefaults.standard.string(forKey: "v3k.vitaHome.theme") ?? defaultId
        return id == defaultId ? builtIn : (load(id: id) ?? builtIn)
    }

    private static func load(id: String) -> VitaTheme? {
        let dir = "ux0/theme/" + id
        guard let data = FileManager.default.contents(atPath: VitaFirmware.absolute(dir + "/theme.xml")) else { return nil }
        let parser = ThemeXML()
        let xml = XMLParser(data: data)
        xml.delegate = parser
        guard xml.parse() else { return nil }
        let wallpapers = parser.images.map { dir + "/" + $0 }.filter { VitaFirmware.exists($0) }
        guard !wallpapers.isEmpty else { return nil }
        let music = parser.music.map { dir + "/" + $0 }.filter { VitaFirmware.exists($0) }
        var color = Color.white
        if let hex = parser.fontColor, let value = UInt32(hex.replacingOccurrences(of: "0x", with: ""), radix: 16) {
            color = Color(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
        }
        return VitaTheme(id: id, name: parser.title ?? id, wallpapers: wallpapers, music: music, fontColor: color)
    }
}

/// Reads the few things the home screen needs from a theme.xml (HomeProperty: m_bgParam images, m_bgmFilePath)
private final class ThemeXML: NSObject, XMLParserDelegate {
    var images: [String] = []
    var music: String?
    var fontColor: String?
    var title: String?
    private var path: [String] = []
    private var text = ""

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        path.append(name)
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty {
            if name == "m_imageFilePath", path.contains("m_bgParam") {
                images.append(value)
            } else if name == "m_bgmFilePath", path.contains("HomeProperty") {
                music = value
            } else if name == "m_fontColor", path.contains("m_bgParam"), fontColor == nil {
                fontColor = value
            } else if name == "m_default", path.contains("m_title"), title == nil {
                title = value
            }
        }
        path.removeLast()
        text = ""
    }
}

/// The home music of the Vita (ATRAC9 file from the firmware or a theme), decoded to a WAV once and played in a loop.
/// MenuMusic uses it instead of the generated songs when Settings > Music asks for it.
@MainActor
final class VitaBGM {
    static let shared = VitaBGM()

    private var player: AVAudioPlayer?
    private var loadedSource = ""
    private var failedSource = ""
    private var loading = false
    private var wantsToPlay = false

    /// Where the music would come from, nil when the Vita music isn't used (setting off) or not available
    var source: String? {
        guard UserDefaults.standard.bool(forKey: "v3k.vitaMusic") else { return nil }
        guard let path = VitaTheme.current().music ?? (VitaFirmware.exists(VitaFirmware.defaultMusicPath) ? VitaFirmware.defaultMusicPath : nil) else { return nil }
        return path == failedSource ? nil : path
    }

    var isActive: Bool { source != nil }

    func play(volume: Double) {
        guard let source else { return }
        wantsToPlay = true
        if loadedSource == source, let player {
            player.volume = Float(volume)
            if !player.isPlaying { player.play() }
            return
        }
        guard !loading else { return }
        loading = true
        let input = VitaFirmware.absolute(source)
        DispatchQueue.global(qos: .utility).async {
            let output = Self.cachedWav(for: input)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.finishLoading(source: source, wav: output, volume: volume) }
            }
        }
    }

    func pause() {
        wantsToPlay = false
        player?.pause()
    }

    private func finishLoading(source: String, wav: String?, volume: Double) {
        loading = false
        guard let wav, let newPlayer = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: wav)) else {
            v3k_log_ui("Vita music: could not decode \(source)")
            failedSource = source
            MenuMusic.shared.settingsChanged() // back to the generated songs
            return
        }
        newPlayer.numberOfLoops = -1
        newPlayer.volume = Float(volume)
        player?.stop()
        player = newPlayer
        loadedSource = source
        v3k_log_ui("Vita music: playing \(source)")
        if wantsToPlay { newPlayer.play() }
    }

    /// nonisolated: runs on a background queue
    nonisolated private static func cachedWav(for input: String) -> String? {
        let ext = (input as NSString).pathExtension.lowercased()
        guard ext == "at9" else { return FileManager.default.fileExists(atPath: input) ? input : nil }
        let attributes = try? FileManager.default.attributesOfItem(atPath: input)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        let folder = (NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true).first ?? NSTemporaryDirectory() as String) + "/VitaMusic"
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        // A stable hash (String.hashValue changes on every launch)
        var hash: UInt32 = 5381
        for byte in input.utf8 { hash = hash &* 33 &+ UInt32(byte) }
        let name = String(format: "%08x-%d.wav", hash, size)
        let output = folder + "/" + name
        if FileManager.default.fileExists(atPath: output) { return output }
        return v3k_decode_at9(input, output) ? output : nil
    }
}

/// Page layout of the Vita home screen: ten bubbles per page, staggered 3 - 2 - 3 - 2
enum VitaLayout {
    static let perPage = 10
    static let rows = [3, 2, 3, 2]

    static func pages(_ apps: [GameApp]) -> [[GameApp]] {
        stride(from: 0, to: max(apps.count, 1), by: perPage).map { start in
            Array(apps[min(start, apps.count)..<min(start + perPage, apps.count)])
        }
    }
}

struct VitaHomeView: View {
    let apps: [GameApp]
    let onLaunch: (GameApp) -> Void
    let onDetails: (GameApp) -> Void
    let onDelete: (GameApp) -> Void
    let onDeleteSave: (GameApp) -> Void
    let onSettings: () -> Void
    let onImport: () -> Void

    @AppStorage("v3k.vitaHome.lockScreen") private var showLockScreen = true
    @AppStorage("v3k.vitaHome.theme") private var themeId = VitaTheme.defaultId
    @State private var locked = true
    @State private var page = 0
    @State private var selected: GameApp?
    @State private var lockOffset: CGFloat = 0

    private var ordered: [GameApp] {
        // The Vita lists the most recently used application first
        apps.sorted { ($0.lastPlayed, $1.title) > ($1.lastPlayed, $0.title) }
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                wallpaper.id(themeId).frame(width: proxy.size.width, height: proxy.size.height).clipped()

                VStack(spacing: 0) {
                    VitaInfoBar().padding(.top, proxy.safeAreaInsets.top)
                    pager(size: proxy.size)
                    pageDots
                    dock.padding(.bottom, max(proxy.safeAreaInsets.bottom, 10))
                }

                if let app = selected {
                    LiveAreaView(app: app, close: { withAnimation(.easeOut(duration: 0.2)) { selected = nil } },
                                 start: { selected = nil; onLaunch(app) },
                                 details: { onDetails(app) })
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                        .zIndex(2)
                }

                if locked && showLockScreen {
                    VitaLockScreen()
                        .offset(y: lockOffset)
                        .gesture(DragGesture()
                            .onChanged { lockOffset = min(0, $0.translation.height) }
                            .onEnded { value in
                                if value.translation.height < -80 || abs(value.translation.width) > 120 {
                                    withAnimation(.easeOut(duration: 0.3)) { lockOffset = -proxy.size.height }
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { locked = false; lockOffset = 0 }
                                } else {
                                    withAnimation(.spring()) { lockOffset = 0 }
                                }
                            })
                        .onTapGesture { withAnimation(.easeOut(duration: 0.3)) { locked = false } }
                        .zIndex(3)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .ignoresSafeArea()
        .background(Color.black)
        .animation(.easeOut(duration: 0.2), value: selected)
    }

    // MARK: Pieces

    private var wallpaper: some View {
        let theme = VitaTheme.current()
        let paths = theme.wallpapers
        return ZStack {
            LinearGradient(colors: [Color(red: 0.05, green: 0.25, blue: 0.55), Color(red: 0.02, green: 0.08, blue: 0.2)],
                           startPoint: .top, endPoint: .bottom)
            if !paths.isEmpty, let image = VitaFirmware.image(atPath: paths[min(page, paths.count - 1)]) {
                Image(uiImage: image).resizable().scaledToFill().id(page)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: page)
    }

    private func pager(size: CGSize) -> some View {
        let pages = VitaLayout.pages(ordered)
        return TabView(selection: $page) {
            ForEach(Array(pages.enumerated()), id: \.offset) { index, items in
                VitaPage(items: items, width: size.width, tap: { app in selected = app },
                         menu: { app in
                             Button { onLaunch(app) } label: { Label("Start", systemImage: "play.fill") }
                             Button { onDetails(app) } label: { Label("Game settings, patches & saves", systemImage: "slider.horizontal.3") }
                             Button(role: .destructive) { onDeleteSave(app) } label: { Label("Delete save data", systemImage: "externaldrive.badge.minus") }
                             Button(role: .destructive) { onDelete(app) } label: { Label("Delete game", systemImage: "trash") }
                         })
                .tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
    }

    private var pageDots: some View {
        let count = VitaLayout.pages(ordered).count
        return HStack(spacing: 8) {
            ForEach(0..<count, id: \.self) { index in
                Circle()
                    .fill(index == page ? Color.white : Color.white.opacity(0.35))
                    .frame(width: 8, height: 8)
            }
        }
        .padding(.vertical, 8)
        .opacity(count > 1 ? 1 : 0)
    }

    private var dock: some View {
        HStack(spacing: 36) {
            dockButton("plus.circle.fill", "Install", onImport)
            dockButton("gearshape.fill", "Settings", onSettings)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 8)
        .background(Capsule().fill(.black.opacity(0.28)))
    }

    private func dockButton(_ symbol: String, _ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: symbol).font(.title2)
                Text(title).font(.caption2)
            }
            .foregroundStyle(.white)
        }
    }
}

/// One page of bubbles, staggered like the real home screen
private struct VitaPage<MenuContent: View>: View {
    let items: [GameApp]
    let width: CGFloat
    let tap: (GameApp) -> Void
    @ViewBuilder let menu: (GameApp) -> MenuContent

    var body: some View {
        GeometryReader { proxy in
            let bubble = min(proxy.size.width / 3.6, proxy.size.height / 4.6, 120)
            let spacing = bubble * 0.28
            VStack(spacing: spacing * 0.9) {
                ForEach(Array(rowSlices().enumerated()), id: \.offset) { _, row in
                    HStack(spacing: spacing) {
                        ForEach(row) { app in
                            VitaBubble(app: app, size: bubble).onTapGesture { tap(app) }.contextMenu { menu(app) }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func rowSlices() -> [[GameApp]] {
        var out: [[GameApp]] = []
        var index = 0
        for count in VitaLayout.rows {
            guard index < items.count else { break }
            out.append(Array(items[index..<min(index + count, items.count)]))
            index += count
        }
        return out
    }
}

struct VitaBubble: View {
    let app: GameApp
    let size: CGFloat
    @State private var floatUp = false

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().fill(Color.white.opacity(0.18))
                if let icon = app.icon {
                    Image(uiImage: icon).resizable().scaledToFill()
                } else {
                    Image(systemName: "gamecontroller.fill").font(.system(size: size * 0.4)).foregroundStyle(.white)
                }
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(
                Circle().stroke(LinearGradient(colors: [.white.opacity(0.9), .white.opacity(0.15)], startPoint: .top, endPoint: .bottom), lineWidth: 2)
            )
            .overlay(
                // Soft glass highlight on the upper half
                Ellipse().fill(LinearGradient(colors: [.white.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom))
                    .frame(width: size * 0.8, height: size * 0.4).offset(y: -size * 0.28).allowsHitTesting(false)
            )
            .shadow(color: .black.opacity(0.35), radius: 8, y: 6)
            .offset(y: floatUp ? -3 : 3)

            Text(app.title)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
                .frame(width: size * 1.1)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: Double.random(in: 2.2...3.2)).repeatForever(autoreverses: true)) { floatUp = true }
        }
        .contentShape(Rectangle())
    }
}

struct VitaInfoBar: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 20)) { context in
            HStack(spacing: 12) {
                Spacer()
                Image(systemName: "wifi").font(.caption)
                batteryView
                Text(context.date, format: .dateTime.hour().minute())
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .frame(height: 30)
            .background(LinearGradient(colors: [.black.opacity(0.45), .clear], startPoint: .top, endPoint: .bottom))
        }
    }

    private var batteryView: some View {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let level = UIDevice.current.batteryLevel
        return HStack(spacing: 3) {
            Text(level >= 0 ? "\(Int(level * 100))%" : "").font(.caption2)
            Image(systemName: level >= 0 && level < 0.2 ? "battery.25" : "battery.100").font(.caption)
        }
    }
}

struct VitaLockScreen: View {
    var body: some View {
        ZStack {
            if let image = VitaFirmware.lockScreen {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                LinearGradient(colors: [Color(red: 0.02, green: 0.1, blue: 0.3), .black], startPoint: .top, endPoint: .bottom)
            }
            VStack {
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    VStack(spacing: 2) {
                        Text(context.date, format: .dateTime.hour().minute())
                            .font(.system(size: 64, weight: .thin))
                        Text(context.date, format: .dateTime.weekday(.wide).month().day())
                            .font(.system(size: 18, weight: .regular))
                    }
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 4)
                }
                Spacer()
                Text("Swipe up or tap to start")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.bottom, 40)
            }
        }
        .ignoresSafeArea()
    }
}

/// The LiveArea of a game: its own background, the icon and the big Start button
struct LiveAreaView: View {
    let app: GameApp
    let close: () -> Void
    let start: () -> Void
    let details: () -> Void

    @State private var showingInfo = false

    private var contents: String { (app.path as NSString).appendingPathComponent("sce_sys/livearea/contents") }

    private func image(_ name: String) -> UIImage? {
        UIImage(contentsOfFile: (contents as NSString).appendingPathComponent(name))
    }

    var body: some View {
        ZStack {
            if let bg = image("bg0.png") ?? image("bg.png") {
                Image(uiImage: bg).resizable().scaledToFill()
            } else {
                LinearGradient(colors: [Color(red: 0.12, green: 0.2, blue: 0.4), .black], startPoint: .top, endPoint: .bottom)
            }
            Color.black.opacity(0.25)

            VStack(spacing: 18) {
                Spacer()
                if let icon = app.icon {
                    Image(uiImage: icon).resizable().scaledToFill()
                        .frame(width: 128, height: 128)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .shadow(radius: 10)
                }
                Text(app.title).font(.title3.weight(.semibold)).multilineTextAlignment(.center).foregroundStyle(.white)
                Button(action: start) {
                    Text("Start")
                        .font(.title3.weight(.semibold))
                        .padding(.horizontal, 60).padding(.vertical, 12)
                        .background(Capsule().fill(.white.opacity(0.9)))
                        .foregroundStyle(.black)
                }
                HStack(spacing: 24) {
                    Button { showingInfo = true } label: { Label("Information", systemImage: "info.circle") }
                    Button(action: details) { Label("Game settings", systemImage: "slider.horizontal.3") }
                }
                .font(.footnote).foregroundStyle(.white.opacity(0.9))
                Spacer()
                Button(action: close) {
                    Image(systemName: "chevron.down.circle.fill").font(.largeTitle).foregroundStyle(.white.opacity(0.85))
                }
                .padding(.bottom, 30)
            }
            .padding(.horizontal, 30)
        }
        .ignoresSafeArea()
        .gesture(DragGesture().onEnded { if $0.translation.height > 80 { close() } })
        .sheet(isPresented: $showingInfo) { GameInfoView(app: app) }
    }
}

/// The information screen of a game: what is known about it on this device
struct GameInfoView: View {
    let app: GameApp
    @Environment(\.dismiss) private var dismiss

    /// Pictures that ship with the game: LiveArea backgrounds and the start-up / pause pictures
    private var pictures: [UIImage] {
        let names = ["sce_sys/livearea/contents/bg0.png", "sce_sys/livearea/contents/bg.png", "sce_sys/livearea/contents/startup.png",
                     "sce_sys/pic0.png", "sce_sys/pic1.png"]
        var seen = Set<String>()
        return names.compactMap { name in
            let path = (app.path as NSString).appendingPathComponent(name)
            guard seen.insert(path).inserted else { return nil }
            return UIImage(contentsOfFile: path)
        }
    }

    private var lastPlayedText: String {
        guard app.lastPlayed > 0 else { return "Never" }
        return Date(timeIntervalSince1970: TimeInterval(app.lastPlayed)).formatted(date: .abbreviated, time: .shortened)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        if let icon = app.icon {
                            Image(uiImage: icon).resizable().scaledToFill().frame(width: 72, height: 72)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(app.title).font(.headline)
                            Text(app.titleId).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
                if !pictures.isEmpty {
                    Section("Pictures") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(Array(pictures.enumerated()), id: \.offset) { _, image in
                                    Image(uiImage: image).resizable().scaledToFit().frame(height: 120)
                                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                }
                            }
                        }
                    }
                }
                Section("Details") {
                    if !app.version.isEmpty { LabeledContent("Version", value: app.version) }
                    if !app.category.isEmpty { LabeledContent("Type", value: app.category) }
                    LabeledContent("Last played", value: lastPlayedText)
                    Text(app.playTimeText)
                }
                if let compatibility = app.compatibility {
                    Section("Compatibility in Vita3K") {
                        CompatibilityBadge(compatibility: compatibility)
                        Text(compatibility.detail).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Text("Descriptions, ratings and screenshots come from the PlayStation Store, which isn't available offline. The pictures above are the ones that came with the game.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Information")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
    }
}
