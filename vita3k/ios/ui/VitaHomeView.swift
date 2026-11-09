// Vita3K emulator project
// Copyright (C) 2026 Vita3K team
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import UIKit

/// Assets of the installed PS Vita firmware (vs0 partition), used to dress the home screen like the real thing.
enum VitaFirmware {
    private static var cache: [String: UIImage] = [:]

    static var root: String {
        guard let cPath = v3k_storage_path() else { return "" }
        return String(cString: cPath)
    }

    /// Image below vs0/, nil when the firmware doesn't have it
    static func image(_ relative: String) -> UIImage? {
        if let cached = cache[relative] { return cached }
        let path = (root as NSString).appendingPathComponent("vs0/" + relative)
        guard let image = UIImage(contentsOfFile: path) else { return nil }
        cache[relative] = image
        return image
    }

    /// Default home wallpaper: the first of the firmware's default themes that has one
    static var wallpaper: UIImage? {
        for app in ["NPXS10002", "NPXS10006", "NPXS10013", "NPXS10018", "NPXS10098"] {
            if let image = image("app/\(app)/sce_sys/pic0.png") { return image }
        }
        return nil
    }

    /// The start (lock) screen picture
    static var lockScreen: UIImage? { image("data/internal/keylock/keylock.png") }
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
    let onSettings: () -> Void
    let onImport: () -> Void

    @AppStorage("v3k.vitaHome.lockScreen") private var showLockScreen = true
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
                wallpaper.frame(width: proxy.size.width, height: proxy.size.height).clipped()

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
        Group {
            if let image = VitaFirmware.wallpaper {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                LinearGradient(colors: [Color(red: 0.05, green: 0.25, blue: 0.55), Color(red: 0.02, green: 0.08, blue: 0.2)],
                               startPoint: .top, endPoint: .bottom)
            }
        }
    }

    private func pager(size: CGSize) -> some View {
        let pages = VitaLayout.pages(ordered)
        return TabView(selection: $page) {
            ForEach(Array(pages.enumerated()), id: \.offset) { index, items in
                VitaPage(items: items, width: size.width) { app in
                    selected = app
                }
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
private struct VitaPage: View {
    let items: [GameApp]
    let width: CGFloat
    let tap: (GameApp) -> Void

    var body: some View {
        GeometryReader { proxy in
            let bubble = min(proxy.size.width / 3.6, proxy.size.height / 4.6, 120)
            let spacing = bubble * 0.28
            VStack(spacing: spacing * 0.9) {
                ForEach(Array(rowSlices().enumerated()), id: \.offset) { _, row in
                    HStack(spacing: spacing) {
                        ForEach(row) { app in
                            VitaBubble(app: app, size: bubble).onTapGesture { tap(app) }
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
                Button("Game settings", action: details).font(.footnote).foregroundStyle(.white.opacity(0.85))
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
    }
}
