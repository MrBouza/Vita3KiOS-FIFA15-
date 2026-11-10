// Vita3K emulator project
// Copyright (C) 2026 Vita3K team
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import UIKit

// The PS Vita home screen (Settings > Appearance > PS Vita home screen). Everything is laid out in the
// Vita's own 960 x 544 screen space and scaled to the phone's height; wider phones get more room at the
// sides. Geometry of the LiveArea comes from Vita3K's LiveArea (gate, frames, background), the start
// screen from Vita3K's old home screen code.

// MARK: - Screen space

/// Maps the Vita's 960 x 544 screen onto the view
struct VitaSpace {
    let size: CGSize
    /// Points per Vita pixel
    var s: CGFloat { min(size.height / 544, size.width / 960) }
    /// Width of the view in Vita pixels (960 on a Vita, more on a wide phone)
    var width: CGFloat { size.width / s }
    /// Left edge of the centred 960-wide area, in Vita pixels
    var inset: CGFloat { (width - 960) / 2 }

    func x(_ vita: CGFloat) -> CGFloat { (vita + inset) * s }
    func y(_ vita: CGFloat) -> CGFloat { vita * s }
    func len(_ vita: CGFloat) -> CGFloat { vita * s }
}

// MARK: - Page curl ("peel")

/// The fold of a page whose top-right corner is dragged to `point`: the part of the page that stays and the
/// flap that is folded over (reflected across the fold line)
enum PeelGeometry {
    static func split(size: CGSize, point: CGPoint) -> (keep: [CGPoint], flap: [CGPoint]) {
        let corner = CGPoint(x: size.width, y: 0)
        let rect = [CGPoint(x: 0, y: 0), corner, CGPoint(x: size.width, y: size.height), CGPoint(x: 0, y: size.height)]
        let nx = corner.x - point.x, ny = corner.y - point.y
        let len2 = nx * nx + ny * ny
        guard len2 > 0.5 else { return (rect, []) }
        let mx = (corner.x + point.x) / 2, my = (corner.y + point.y) / 2
        func side(_ q: CGPoint) -> CGFloat { (q.x - mx) * nx + (q.y - my) * ny }
        var keep: [CGPoint] = [], cut: [CGPoint] = []
        for i in 0..<4 {
            let a = rect[i], b = rect[(i + 1) % 4]
            let sa = side(a), sb = side(b)
            if sa <= 0 { keep.append(a) } else { cut.append(a) }
            if (sa <= 0) != (sb <= 0) {
                let t = sa / (sa - sb)
                let q = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
                keep.append(q)
                cut.append(q)
            }
        }
        let flap = cut.map { q -> CGPoint in
            let d = 2 * side(q) / len2
            return CGPoint(x: q.x - d * nx, y: q.y - d * ny)
        }
        return (keep, flap)
    }
}

/// The page that stays, as an animatable shape (so the peel can be animated)
struct PeelPageShape: Shape {
    var point: CGPoint
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(point.x, point.y) }
        set { point = CGPoint(x: newValue.first, y: newValue.second) }
    }

    func path(in rect: CGRect) -> Path {
        let keep = PeelGeometry.split(size: rect.size, point: point).keep
        var path = Path()
        if let first = keep.first {
            path.move(to: first)
            keep.dropFirst().forEach { path.addLine(to: $0) }
            path.closeSubpath()
        }
        return path
    }
}

/// The folded-over back of the page
struct PeelFlapShape: Shape {
    var point: CGPoint
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(point.x, point.y) }
        set { point = CGPoint(x: newValue.first, y: newValue.second) }
    }

    func path(in rect: CGRect) -> Path {
        let flap = PeelGeometry.split(size: rect.size, point: point).flap
        var path = Path()
        if let first = flap.first {
            path.move(to: first)
            flap.dropFirst().forEach { path.addLine(to: $0) }
            path.closeSubpath()
        }
        return path
    }
}

/// A page with a dog-eared top-right corner that is peeled away with a finger, like the Vita's start screen
/// and LiveArea. Peeling it far enough (or flicking) finishes the curl and calls `onPeeled`.
struct Peelable<Content: View>: View {
    /// Size of the dog-ear at rest, in points
    let fold: CGFloat
    let onPeeled: () -> Void
    @ViewBuilder let content: () -> Content

    @State private var point: CGPoint?
    @State private var dragging = false
    @State private var finishing = false

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let rest = CGPoint(x: size.width - fold, y: fold)
            let current = point ?? rest
            ZStack(alignment: .topLeading) {
                content()
                    .frame(width: size.width, height: size.height)
                    .clipShape(PeelPageShape(point: current))
                    // Shadow the page casts under the flap
                    .shadow(color: .black.opacity(0.35), radius: 10, x: -4, y: 6)
                PeelFlapShape(point: current)
                    .fill(LinearGradient(colors: [Color(white: 0.97), Color(white: 0.78), Color(white: 0.9)],
                                         startPoint: .topTrailing, endPoint: .bottomLeading))
                    .shadow(color: .black.opacity(0.45), radius: 8, x: -3, y: 5)
                    .allowsHitTesting(false)
                // Where a finger can grab the corner
                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: max(fold * 2.6, 90), height: max(fold * 2.6, 90))
                    // The gesture belongs to the corner area only (position() comes after it): a gesture added
                    // after position() would cover the whole page and take every touch
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .named("peel"))
                            .onChanged { value in
                                guard !finishing else { return }
                                dragging = true
                                point = CGPoint(x: min(value.location.x, size.width - 4), y: max(value.location.y, 4))
                            }
                            .onEnded { value in
                                guard !finishing else { return }
                                dragging = false
                                let travel = hypot(size.width - value.predictedEndLocation.x, value.predictedEndLocation.y)
                                let moved = hypot(value.translation.width, value.translation.height)
                                // A tap on the corner finishes the peel too (no need to find the exact drag)
                                if travel > size.width * 0.38 || moved < 8 {
                                    finishing = true
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                    withAnimation(.easeIn(duration: 0.38)) {
                                        point = CGPoint(x: -size.width * 1.2, y: size.height * 2.2)
                                    }
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                        onPeeled()
                                        point = nil
                                        finishing = false
                                    }
                                } else {
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { point = nil }
                                }
                            }
                    )
                    .position(x: size.width - max(fold * 1.3, 45), y: max(fold * 1.3, 45))
            }
            .coordinateSpace(name: "peel")
        }
    }
}

// MARK: - Layout of the home pages

enum VitaHomeLayout {
    static let perPage = 10
    /// Bubbles per row, top to bottom
    static let rows = [3, 4, 3]
    /// Row centres (Vita pixels, from the top of the screen) and the distance between bubbles in a row
    static let rowY: [CGFloat] = [126, 284, 442]
    static let pitch: CGFloat = 176
    static let bubble: CGFloat = 108

    /// Centre of slot `index` (0 ... 9) on a page, in Vita pixels
    static func slot(_ index: Int) -> CGPoint {
        var remaining = index
        for (row, count) in rows.enumerated() {
            if remaining < count {
                let x = 492 + (CGFloat(remaining) - CGFloat(count - 1) / 2) * pitch
                return CGPoint(x: x, y: rowY[row])
            }
            remaining -= count
        }
        return CGPoint(x: 492, y: 284)
    }
}

/// One thing on the home screen: a game, or one of the system applications
enum VitaHomeItem: Identifiable, Hashable {
    case game(GameApp)
    case search, contentManager, settings, themes, music, classicLibrary

    var id: String {
        switch self {
        case .game(let app): "game." + app.titleId
        case .search: "sys.search"
        case .contentManager: "sys.content"
        case .settings: "sys.settings"
        case .themes: "sys.themes"
        case .music: "sys.music"
        case .classicLibrary: "sys.library"
        }
    }

    var title: String {
        switch self {
        case .game(let app): app.title
        case .search: "Search"
        case .contentManager: "Content Manager"
        case .settings: "Settings"
        case .themes: "Themes"
        case .music: "Music"
        case .classicLibrary: "Library"
        }
    }
}

// MARK: - Home screen

struct VitaHomeView: View {
    let apps: [GameApp]
    let onLaunch: (GameApp) -> Void
    let onDetails: (GameApp) -> Void
    let onDelete: (GameApp) -> Void
    let onDeleteSave: (GameApp) -> Void
    let onImportFiles: () -> Void
    let onImportFolder: () -> Void
    let onEnterZrif: () -> Void

    @EnvironmentObject private var model: LibraryModel
    @AppStorage("v3k.vitaHome") private var vitaHome = false
    @AppStorage("v3k.vitaHome.lockScreen") private var showStartScreen = true
    @AppStorage("v3k.vitaHome.theme") private var themeId = VitaTheme.defaultId
    @State private var locked = true
    @State private var page = 0
    @State private var openApp: GameApp?
    @State private var searching = false
    @State private var infoApp: GameApp?
    @State private var panel: VitaPanelKind?

    private var theme: VitaTheme { VitaTheme.current() }

    private var items: [VitaHomeItem] {
        // The Vita puts the system applications on the first page and new games after them
        let games = apps.sorted { ($0.lastPlayed, $1.title) > ($1.lastPlayed, $0.title) }.map { VitaHomeItem.game($0) }
        return [.search, .contentManager, .settings, .themes, .music, .classicLibrary] + games
    }

    private var pages: [[VitaHomeItem]] {
        let all = items
        return stride(from: 0, to: all.count, by: VitaHomeLayout.perPage).map {
            Array(all[$0..<min($0 + VitaHomeLayout.perPage, all.count)])
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let space = VitaSpace(size: proxy.size)
            ZStack {
                VitaWallpaper(theme: theme, page: page).id(themeId)

                homePages(space: space)
                    .offset(x: openApp == nil ? 0 : -proxy.size.width * 0.3)
                    .opacity(openApp == nil ? 1 : 0)
                    // Nothing underneath takes touches while a LiveArea, panel or search is open
                    .allowsHitTesting(openApp == nil && panel == nil && !searching && !locked)

                VitaPageDots(count: pages.count, current: page, space: space)
                    .opacity(openApp == nil ? 1 : 0)

                if let app = openApp {
                    Peelable(fold: space.len(44), onPeeled: { openApp = nil }) {
                        VitaLiveArea(app: app, space: space, theme: theme,
                                     start: { launch(app) }, info: { infoApp = app }, settings: { onDetails(app) })
                    }
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
                    .zIndex(2)
                }

                VitaInfoBar(space: space, theme: theme, notices: notices.count, openNotices: { openPanel(.notifications) })
                    .frame(maxHeight: .infinity, alignment: .top).zIndex(3)

                if let kind = panel {
                    Peelable(fold: space.len(44), onPeeled: { panel = nil }) {
                        VitaPanel(kind: kind, space: space, model: model, notices: notices, close: { withAnimation(.easeOut(duration: 0.2)) { panel = nil } },
                                  importFiles: onImportFiles, importFolder: onImportFolder, enterZrif: onEnterZrif)
                    }
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
                    .zIndex(3.5)
                }

                if searching {
                    VitaSearch(apps: apps, space: space, close: { withAnimation(.easeOut(duration: 0.2)) { searching = false } }) { app in
                        withAnimation(.easeOut(duration: 0.2)) { searching = false }
                        open(app)
                    }
                    .transition(.opacity)
                    .zIndex(4)
                }

                if locked && showStartScreen {
                    Peelable(fold: space.len(44), onPeeled: { locked = false }) {
                        VitaStartScreen(space: space, theme: theme)
                    }
                    .zIndex(5)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .ignoresSafeArea()
        .background(Color.black.ignoresSafeArea())
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .sheet(item: $infoApp) { app in GameInfoView(app: app) }
        // Deleting games can leave fewer pages than the one being shown
        .onChange(of: pages.count) { _, count in
            if page >= count { page = max(count - 1, 0) }
        }
    }

    private func homePages(space: VitaSpace) -> some View {
        // The Vita's home pages scroll up and down, one page at a time
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                ForEach(Array(pages.enumerated()), id: \.offset) { index, items in
                    VitaHomePage(items: items, space: space, tap: tap, menu: menu)
                        .frame(width: space.size.width, height: space.size.height)
                        .id(index)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollIndicators(.hidden)
        .scrollPosition(id: Binding<Int?>(get: { page }, set: { page = $0 ?? 0 }))
    }

    private func tap(_ item: VitaHomeItem) {
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        switch item {
        case .game(let app): open(app)
        case .search: withAnimation(.easeOut(duration: 0.2)) { searching = true }
        case .contentManager: openPanel(.contentManager)
        case .settings: openPanel(.settings)
        case .themes: openPanel(.themes)
        case .music: openPanel(.music)
        case .classicLibrary: vitaHome = false
        }
    }

    private func openPanel(_ kind: VitaPanelKind) {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { panel = kind }
    }

    /// What the notification bubble counts: things worth the player's attention
    private var notices: [String] {
        var list: [String] = []
        if !model.hasFirmware { list.append("The PS Vita firmware isn't installed. Install it from Content Manager (PSVUPDAT.PUP).") }
        else if !model.hasFonts { list.append("The firmware's fonts aren't installed. Install the font package from Content Manager.") }
        if model.jitPreparing { list.append("Preparing JIT (\(model.jitProgress)/\(model.jitTarget))…") }
        else if !model.jitEnabled { list.append(model.jitCanRequest ? "JIT is attached; it starts when you launch a game." : "JIT is off: \(model.jitStatus)") }
        if apps.isEmpty { list.append("No games yet. Open Content Manager to install some.") }
        return list
    }

    private func open(_ app: GameApp) {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { openApp = app }
    }

    private func launch(_ app: GameApp) {
        onLaunch(app)
        // Back on the home screen (not this LiveArea) when the game ends
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { openApp = nil }
    }

    @ViewBuilder
    private func menu(_ item: VitaHomeItem) -> some View {
        if case .game(let app) = item {
            Button { onLaunch(app) } label: { Label("Start", systemImage: "play.fill") }
            Button { infoApp = app } label: { Label("Information", systemImage: "info.circle") }
            Button { onDetails(app) } label: { Label("Game settings, patches & saves", systemImage: "slider.horizontal.3") }
            Button(role: .destructive) { onDeleteSave(app) } label: { Label("Delete save data", systemImage: "externaldrive.badge.minus") }
            Button(role: .destructive) { onDelete(app) } label: { Label("Delete game", systemImage: "trash") }
        }
    }
}

// MARK: - Wallpaper

/// The theme's wallpaper for the page; the default theme is the Vita's blue with the PlayStation shapes
/// drifting behind the bubbles
struct VitaWallpaper: View {
    let theme: VitaTheme
    let page: Int

    var body: some View {
        ZStack {
            if theme.id == VitaTheme.defaultId || theme.wallpapers.isEmpty {
                // The default theme: the Vita's blue with the PlayStation shapes
                VitaDefaultBackground()
            } else if let image = VitaFirmware.image(atPath: theme.wallpapers[min(page, theme.wallpapers.count - 1)]) {
                Image(uiImage: image).resizable().scaledToFill()
                    .id(page)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.4), value: page)
        .ignoresSafeArea()
    }
}

/// The default Vita home background: deep blue light with the four PlayStation shapes floating slowly
struct VitaDefaultBackground: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Floater {
        let kind: Int // 0 triangle, 1 circle, 2 cross, 3 square
        let x: CGFloat, y: CGFloat, size: CGFloat
        let speed: Double, phase: Double, spin: Double
    }

    private static let shapes: [Floater] = {
        var generator = SystemRandomNumberGenerator()
        return (0..<22).map { i in
            Floater(kind: i % 4,
                  x: CGFloat.random(in: 0...1, using: &generator),
                  y: CGFloat.random(in: 0...1, using: &generator),
                  size: CGFloat.random(in: 0.05...0.16, using: &generator),
                  speed: Double.random(in: 0.006...0.018, using: &generator),
                  phase: Double.random(in: 0...(2 * .pi), using: &generator),
                  spin: Double.random(in: -0.15...0.15, using: &generator))
        }
    }()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { timeline in
            Canvas { context, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                // Light from the top left fading to the Vita's deep blue
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(
                    Gradient(colors: [Color(red: 0.36, green: 0.62, blue: 0.86), Color(red: 0.10, green: 0.30, blue: 0.62), Color(red: 0.03, green: 0.10, blue: 0.30)]),
                    startPoint: .zero, endPoint: CGPoint(x: size.width * 0.6, y: size.height)))
                context.fill(Path(ellipseIn: CGRect(x: -size.width * 0.2, y: -size.height * 0.6, width: size.width * 1.1, height: size.height * 1.2)),
                             with: .radialGradient(Gradient(colors: [.white.opacity(0.22), .clear]),
                                                   center: CGPoint(x: size.width * 0.25, y: 0), startRadius: 0, endRadius: size.width * 0.6))
                for shape in Self.shapes {
                    let side = shape.size * size.height
                    // Each shape rises slowly and sways; it comes back at the bottom when it leaves the top
                    var y = (shape.y - CGFloat(t * shape.speed).truncatingRemainder(dividingBy: 1.3))
                    if y < -0.15 { y += 1.3 }
                    let x = shape.x + CGFloat(sin(t * 0.2 + shape.phase)) * 0.02
                    let center = CGPoint(x: x * size.width, y: y * size.height)
                    var local = context
                    local.translateBy(x: center.x, y: center.y)
                    local.rotate(by: .radians(t * shape.spin + shape.phase))
                    local.opacity = 0.16
                    local.stroke(path(kind: shape.kind, side: side), with: .color(.white), lineWidth: max(side * 0.07, 2))
                }
            }
        }
        .ignoresSafeArea()
    }

    private func path(kind: Int, side: CGFloat) -> Path {
        let r = side / 2
        var p = Path()
        switch kind {
        case 0:
            p.move(to: CGPoint(x: 0, y: -r))
            p.addLine(to: CGPoint(x: r * 0.95, y: r * 0.7))
            p.addLine(to: CGPoint(x: -r * 0.95, y: r * 0.7))
            p.closeSubpath()
        case 1:
            p.addEllipse(in: CGRect(x: -r, y: -r, width: side, height: side))
        case 2:
            p.move(to: CGPoint(x: -r, y: -r)); p.addLine(to: CGPoint(x: r, y: r))
            p.move(to: CGPoint(x: r, y: -r)); p.addLine(to: CGPoint(x: -r, y: r))
        default:
            p.addRect(CGRect(x: -r * 0.85, y: -r * 0.85, width: side * 0.85, height: side * 0.85))
        }
        return p
    }
}

// MARK: - Pages and bubbles

private struct VitaHomePage<MenuContent: View>: View {
    let items: [VitaHomeItem]
    let space: VitaSpace
    let tap: (VitaHomeItem) -> Void
    @ViewBuilder let menu: (VitaHomeItem) -> MenuContent

    var body: some View {
        ZStack {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                let slot = VitaHomeLayout.slot(index)
                // The button is exactly the bubble (and its name); positioning comes last so only the
                // bubble itself takes touches
                Button { tap(item) } label: {
                    VitaBubbleView(item: item, space: space)
                }
                .buttonStyle(VitaBubbleButtonStyle())
                .modifier(VitaItemMenu(item: item, menu: menu))
                .modifier(VitaFloat(amount: space.len(3), seed: index))
                .position(x: space.x(slot.x), y: space.y(slot.y))
            }
        }
    }
}

/// Bubbles bob gently, each at its own pace (an animation that runs by itself, not a redraw every frame:
/// per-frame redraws made taps unreliable)
private struct VitaFloat: ViewModifier {
    let amount: CGFloat
    let seed: Int
    @State private var up = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .offset(y: reduceMotion ? 0 : (up ? -amount : amount))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 2.0 + Double(seed % 5) * 0.35).repeatForever(autoreverses: true).delay(Double(seed % 7) * 0.2)) {
                    up = true
                }
            }
    }
}

/// Press feedback of a bubble: it squashes while the finger is on it
private struct VitaBubbleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .brightness(configuration.isPressed ? -0.08 : 0)
            .animation(.spring(response: 0.25, dampingFraction: 0.55), value: configuration.isPressed)
    }
}

/// The long-press menu: games only (an empty menu on the system bubbles got in the way of their taps)
private struct VitaItemMenu<MenuContent: View>: ViewModifier {
    let item: VitaHomeItem
    let menu: (VitaHomeItem) -> MenuContent

    func body(content: Content) -> some View {
        if case .game = item {
            content.contextMenu { menu(item) }
        } else {
            content
        }
    }
}

struct VitaBubbleView: View {
    let item: VitaHomeItem
    let space: VitaSpace

    var body: some View {
        let d = space.len(VitaHomeLayout.bubble)
        VStack(spacing: space.len(6)) {
            ZStack {
                switch item {
                case .game(let app):
                    if let icon = app.icon {
                        Image(uiImage: icon).resizable().scaledToFill()
                    } else {
                        systemIcon("gamecontroller.fill", [Color(white: 0.5), Color(white: 0.25)])
                    }
                case .search:
                    systemIcon("magnifyingglass", [Color(red: 0.98, green: 0.62, blue: 0.16), Color(red: 0.9, green: 0.38, blue: 0.05)])
                case .contentManager:
                    systemIcon("arrow.down.circle", [Color(red: 0.25, green: 0.7, blue: 0.95), Color(red: 0.05, green: 0.4, blue: 0.75)])
                case .settings:
                    systemIcon("gearshape.fill", [Color(white: 0.62), Color(white: 0.32)])
                case .themes:
                    systemIcon("paintpalette.fill", [Color(red: 0.95, green: 0.45, blue: 0.7), Color(red: 0.6, green: 0.2, blue: 0.75)])
                case .music:
                    systemIcon("music.note", [Color(red: 0.45, green: 0.85, blue: 0.55), Color(red: 0.1, green: 0.55, blue: 0.4)])
                case .classicLibrary:
                    systemIcon("square.grid.2x2.fill", [Color(red: 0.55, green: 0.6, blue: 0.95), Color(red: 0.25, green: 0.3, blue: 0.7)])
                }
            }
            .frame(width: d, height: d)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.85), lineWidth: max(space.len(2.5), 1.5)))
            .shadow(color: .black.opacity(0.4), radius: space.len(6), y: space.len(4))

            Text(item.title)
                .font(VitaFont.font(space.len(17)))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.75), radius: 2, y: 1)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: space.len(VitaHomeLayout.pitch - 14), height: space.len(40), alignment: .top)
        }
        .contentShape(Rectangle())
    }

    private func systemIcon(_ symbol: String, _ colors: [Color]) -> some View {
        ZStack {
            LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
            Image(systemName: symbol)
                .font(.system(size: space.len(48), weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
        }
    }
}

/// The page dots down the left side
struct VitaPageDots: View {
    let count: Int
    let current: Int
    let space: VitaSpace

    var body: some View {
        VStack(spacing: space.len(14)) {
            ForEach(0..<count, id: \.self) { index in
                Circle()
                    .fill(index == current ? Color.white : Color.white.opacity(0.35))
                    .frame(width: space.len(index == current ? 12 : 9), height: space.len(index == current ? 12 : 9))
                    .shadow(color: .black.opacity(0.3), radius: 2)
            }
        }
        .animation(.easeOut(duration: 0.2), value: current)
        .position(x: space.x(36), y: space.size.height / 2 + space.len(16))
        .opacity(count > 1 ? 1 : 0)
        .allowsHitTesting(false)
    }
}

// MARK: - Information bar

struct VitaInfoBar: View {
    let space: VitaSpace
    let theme: VitaTheme
    var notices = 0
    var openNotices: (() -> Void)? = nil
    @ObservedObject private var music = MenuMusic.shared

    var body: some View {
        TimelineView(.everyMinute) { context in
            HStack(spacing: space.len(14)) {
                if !music.nowPlaying.isEmpty && (UserDefaults.standard.object(forKey: "v3k.musicEnabled") as? Bool ?? true) {
                    Label(music.nowPlaying, systemImage: "music.note")
                        .font(VitaFont.font(space.len(16)))
                        .lineLimit(1)
                        .opacity(0.85)
                        .padding(.leading, space.len(70 + max(space.inset, 0)))
                }
                Spacer()
                Image(systemName: "wifi").font(.system(size: space.len(17), weight: .semibold))
                battery
                Text(context.date, format: .dateTime.hour().minute())
                    .font(VitaFont.font(space.len(20)))
                    .monospacedDigit()
                // The notification bubble at the far right: tap it for the notices
                Button { openNotices?() } label: {
                    Circle()
                        .fill(LinearGradient(colors: notices > 0
                                             ? [Color(red: 1, green: 0.75, blue: 0.3), Color(red: 0.95, green: 0.45, blue: 0.1)]
                                             : [Color(red: 0.35, green: 0.75, blue: 1), Color(red: 0.05, green: 0.45, blue: 0.85)],
                                             startPoint: .top, endPoint: .bottom))
                        .overlay(Circle().strokeBorder(.white.opacity(0.8), lineWidth: 1))
                        .overlay {
                            if notices > 0 {
                                Text("\(notices)").font(VitaFont.font(space.len(14), bold: true)).foregroundStyle(.white)
                            }
                        }
                        .frame(width: space.len(26), height: space.len(26))
                }
                .buttonStyle(.plain)
                .allowsHitTesting(openNotices != nil)
                .contextMenu {
                    // A way out that doesn't depend on any other control
                    Button { UserDefaults.standard.set(false, forKey: "v3k.vitaHome") } label: {
                        Label("Back to the normal library", systemImage: "square.grid.2x2")
                    }
                }
            }
            .foregroundStyle(.white)
            // Clear of the dog-ear in the corner and of the phone's rounded corner
            .padding(.trailing, space.len(max(space.inset, 0) + 58))
            .frame(height: space.len(32))
            .frame(maxWidth: .infinity)
            .background(theme.barColor?.opacity(0.85) ?? Color.black.opacity(0.5))
        }
    }

    private var battery: some View {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let level = UIDevice.current.batteryLevel
        let charging = UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full
        let symbol = charging ? "battery.100.bolt" : level < 0 ? "battery.100" : level < 0.15 ? "battery.0" : level < 0.4 ? "battery.25" : level < 0.65 ? "battery.50" : level < 0.9 ? "battery.75" : "battery.100"
        return Image(systemName: symbol).font(.system(size: space.len(19)))
    }
}

// MARK: - Start screen

/// The start screen: the picture in a rounded white frame, with the clock and date in the corner
struct VitaStartScreen: View {
    let space: VitaSpace
    let theme: VitaTheme

    private var picture: UIImage? {
        if let path = theme.startImage, let image = VitaFirmware.image(atPath: path) { return image }
        return VitaFirmware.lockScreen
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Group {
                if let picture {
                    Image(uiImage: picture).resizable().scaledToFill()
                } else {
                    VitaDefaultBackground()
                }
            }
            .frame(width: space.size.width, height: space.size.height)
            .clipped()

            // The frame of the start screen: 32 px in from the edges below the information bar, 20 px corners
            RoundedRectangle(cornerRadius: space.len(20), style: .continuous)
                .strokeBorder(.white, lineWidth: max(space.len(2), 1))
                .frame(width: space.len(960 - 64), height: space.size.height - space.len(32) - space.len(64))
                .offset(x: space.x(32), y: space.len(32 + 32))

            TimelineView(.periodic(from: .now, by: 1)) { context in
                let rightAligned = theme.dateLayout == 2
                let top = theme.dateLayout == 1
                // Vita3K's start screen: date 186 px and clock 146 px above the bottom (468 / 426 at the top)
                let dateY: CGFloat = top ? 544 - 468 : 544 - 186
                let clockY: CGFloat = top ? 544 - 426 : 544 - 146
                ZStack(alignment: rightAligned ? .topTrailing : .topLeading) {
                    Text(context.date, format: .dateTime.weekday(.wide).month(.wide).day())
                        .font(VitaFont.font(space.len(30)))
                        .offset(x: rightAligned ? -space.len(max(space.inset, 0) + 50) : space.x(60), y: space.len(dateY))
                    Text(context.date, format: .dateTime.hour(.defaultDigits(amPM: .abbreviated)).minute())
                        .font(VitaFont.font(space.len(100)))
                        .monospacedDigit()
                        .offset(x: rightAligned ? -space.len(max(space.inset, 0) + 50) : space.x(80), y: space.len(clockY - 12))
                }
                .foregroundStyle(theme.dateColor)
                .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                .frame(width: space.size.width, height: space.size.height, alignment: rightAligned ? .topTrailing : .topLeading)
            }

            // A hint for anyone who has never held a Vita
            Text("Drag the corner, or tap it, to start")
                .font(VitaFont.font(space.len(15)))
                .foregroundStyle(theme.dateColor.opacity(0.8))
                .shadow(color: .black.opacity(0.4), radius: 2)
                .frame(width: space.size.width)
                .offset(y: space.size.height - space.len(58))

            VitaInfoBar(space: space, theme: theme)
        }
        .frame(width: space.size.width, height: space.size.height)
        .background(Color.black)
    }
}

// MARK: - LiveArea

/// Pictures of LiveAreas, kept after the first read (a LiveArea draws many times while it animates)
enum VitaImageCache {
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()
    private static let missing = NSCache<NSString, NSNumber>()

    static func image(atPath path: String) -> UIImage? {
        let key = path as NSString
        if let image = cache.object(forKey: key) { return image }
        if missing.object(forKey: key) != nil { return nil }
        guard let image = UIImage(contentsOfFile: path) else {
            missing.setObject(1, forKey: key)
            return nil
        }
        cache.setObject(image, forKey: key, cost: Int(image.size.width * image.size.height * 4))
        return image
    }
}

/// What a game's sce_sys/livearea/contents/template.xml says
struct LiveAreaTemplate {
    struct Frame {
        let id: String
        var background: String?
        var image: String?
        var text: String?
        var textColor: Color = .white
        var textSize: CGFloat = 0
    }

    var style = "a1"
    var background: String?
    var gate: String?
    var frames: [Frame] = []

    static func load(contents: String) -> LiveAreaTemplate {
        var template = LiveAreaTemplate()
        guard let data = FileManager.default.contents(atPath: (contents as NSString).appendingPathComponent("template.xml")) else { return template }
        let parser = LiveAreaXML()
        let xml = XMLParser(data: data)
        xml.delegate = parser
        _ = xml.parse()
        template.style = parser.style ?? "a1"
        template.background = parser.background
        template.gate = parser.gate
        template.frames = parser.frames
        return template
    }

    /// Gate position (distance from the right and bottom edges) and frame rectangles (distance from the right
    /// and bottom, size) per style, from Vita3K's LiveArea
    static let styles: [String: (gate: CGPoint, frames: [String: (CGPoint, CGSize)])] = [
        "a1": (CGPoint(x: 620, y: 361), ["frame1": (CGPoint(x: 900, y: 414), CGSize(width: 260, height: 260)),
                                         "frame2": (CGPoint(x: 320, y: 414), CGSize(width: 260, height: 260)),
                                         "frame3": (CGPoint(x: 900, y: 154), CGSize(width: 840, height: 150))]),
        "a2": (CGPoint(x: 620, y: 395), ["frame1": (CGPoint(x: 900, y: 404), CGSize(width: 260, height: 400)),
                                         "frame2": (CGPoint(x: 320, y: 404), CGSize(width: 260, height: 400)),
                                         "frame3": (CGPoint(x: 640, y: 204), CGSize(width: 320, height: 200))]),
        "a3": (CGPoint(x: 620, y: 395), ["frame1": (CGPoint(x: 900, y: 414), CGSize(width: 260, height: 200)),
                                         "frame2": (CGPoint(x: 320, y: 414), CGSize(width: 260, height: 200)),
                                         "frame3": (CGPoint(x: 900, y: 214), CGSize(width: 260, height: 210)),
                                         "frame4": (CGPoint(x: 640, y: 214), CGSize(width: 320, height: 210)),
                                         "frame5": (CGPoint(x: 320, y: 214), CGSize(width: 260, height: 210))]),
        "a4": (CGPoint(x: 620, y: 395), ["frame1": (CGPoint(x: 900, y: 414), CGSize(width: 260, height: 200)),
                                         "frame2": (CGPoint(x: 320, y: 414), CGSize(width: 260, height: 200)),
                                         "frame3": (CGPoint(x: 900, y: 214), CGSize(width: 840, height: 70)),
                                         "frame4": (CGPoint(x: 900, y: 144), CGSize(width: 840, height: 70)),
                                         "frame5": (CGPoint(x: 900, y: 74), CGSize(width: 840, height: 70))]),
        "a5": (CGPoint(x: 380, y: 395), ["frame1": (CGPoint(x: 900, y: 412), CGSize(width: 480, height: 68)),
                                         "frame2": (CGPoint(x: 900, y: 344), CGSize(width: 480, height: 68)),
                                         "frame3": (CGPoint(x: 900, y: 276), CGSize(width: 480, height: 68)),
                                         "frame4": (CGPoint(x: 900, y: 208), CGSize(width: 480, height: 68)),
                                         "frame5": (CGPoint(x: 900, y: 140), CGSize(width: 480, height: 68)),
                                         "frame6": (CGPoint(x: 900, y: 72), CGSize(width: 480, height: 68)),
                                         "frame7": (CGPoint(x: 420, y: 214), CGSize(width: 360, height: 210))]),
        "psmobile": (CGPoint(x: 380, y: 345), ["frame1": (CGPoint(x: 866, y: 414), CGSize(width: 446, height: 154)),
                                               "frame2": (CGPoint(x: 866, y: 249.5), CGSize(width: 446, height: 109)),
                                               "frame3": (CGPoint(x: 866, y: 119), CGSize(width: 196, height: 58)),
                                               "frame4": (CGPoint(x: 866, y: 34), CGSize(width: 772, height: 30))]),
    ]
}

private final class LiveAreaXML: NSObject, XMLParserDelegate {
    var style: String?
    var background: String?
    var gate: String?
    var frames: [LiveAreaTemplate.Frame] = []
    private var path: [String] = []
    private var attributesStack: [[String: String]] = []
    private var text = ""
    private var backgroundIsDefault = false
    private var gateIsDefault = false

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        if name == "livearea" { style = attributes["style"] }
        if path.count == 1, let id = attributes["id"] { frames.append(LiveAreaTemplate.Frame(id: id)) }
        path.append(name)
        attributesStack.append(attributes)
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let attributes = attributesStack.last ?? [:]
        let inFrame = path.count >= 2 && !(frames.isEmpty) && path[1] != "livearea-background" && path[1] != "gate"
        if !value.isEmpty {
            if path.contains("livearea-background"), name == "image" {
                // The image marked default="on" wins; otherwise the first one
                let isDefault = attributes["default"] == "on"
                if background == nil || (isDefault && !backgroundIsDefault) {
                    background = value
                    backgroundIsDefault = isDefault
                }
            } else if path.contains("gate"), name == "startup-image" || name == "image" {
                let isDefault = attributes["default"] == "on"
                if gate == nil || (isDefault && !gateIsDefault) {
                    gate = value
                    gateIsDefault = isDefault
                }
            } else if inFrame, path.contains("liveitem"), var frame = frames.last {
                switch name {
                case "background": if frame.background == nil { frame.background = value }
                case "image": if frame.image == nil { frame.image = value }
                case "str":
                    if frame.text == nil {
                        frame.text = value
                        if let color = VitaTheme.color(hex: attributes["color"]) { frame.textColor = color }
                        frame.textSize = CGFloat(Double(attributes["size"] ?? "") ?? 0)
                    }
                default: break
                }
                frames[frames.count - 1] = frame
            }
        }
        path.removeLast()
        attributesStack.removeLast()
        text = ""
    }
}

/// A game's LiveArea: its background, frames and gate with the Start button, as the Vita lays them out.
/// Start zooms the game's picture out of the gate like the Vita does before the game starts.
struct VitaLiveArea: View {
    let app: GameApp
    let space: VitaSpace
    let theme: VitaTheme
    let start: () -> Void
    let info: () -> Void
    let settings: () -> Void

    @State private var template = LiveAreaTemplate()
    @State private var starting = false
    @State private var showingManual = false

    private var contents: String { (app.path as NSString).appendingPathComponent("sce_sys/livearea/contents") }

    private func image(_ name: String?) -> UIImage? {
        guard let name, !name.isEmpty else { return nil }
        return VitaImageCache.image(atPath: (contents as NSString).appendingPathComponent(name))
    }

    private var manualPages: [String] { VitaManual.pages(appPath: app.path) }

    var body: some View {
        let style = LiveAreaTemplate.styles[template.style] ?? LiveAreaTemplate.styles["a1"]!
        let gate = CGRect(x: 960 - style.gate.x, y: 544 - style.gate.y, width: 280, height: 158)
        ZStack(alignment: .topLeading) {
            // Behind the LiveArea: the home wallpaper, darkened
            VitaWallpaper(theme: theme, page: 0)
            Color.black.opacity(0.45)

            // Background: 840 x 500 at 60, 44
            Group {
                if let bg = image(template.background) ?? image("bg0.png") ?? image("bg.png") {
                    Image(uiImage: bg).resizable()
                } else {
                    Color(red: 148 / 255, green: 164 / 255, blue: 173 / 255)
                }
            }
            .frame(width: space.len(840), height: space.len(500))
            .clipShape(RoundedRectangle(cornerRadius: space.len(6), style: .continuous))
            .shadow(color: .black.opacity(0.4), radius: space.len(8))
            .position(x: space.x(60 + 420), y: space.y(44 + 250))

            // Frames
            ForEach(template.frames, id: \.id) { frame in
                if let layout = style.frames[frame.id] {
                    let rect = CGRect(x: 960 - layout.0.x, y: 544 - layout.0.y, width: layout.1.width, height: layout.1.height)
                    ZStack {
                        if let bg = image(frame.background) {
                            Image(uiImage: bg).resizable()
                        }
                        if let picture = image(frame.image) {
                            Image(uiImage: picture).resizable().scaledToFit()
                                .frame(maxWidth: space.len(min(picture.size.width, rect.width)), maxHeight: space.len(min(picture.size.height, rect.height)))
                        }
                        if let text = frame.text {
                            Text(text)
                                .font(VitaFont.font(space.len(max(frame.textSize > 0 ? frame.textSize / 2 : 14, 10))))
                                .foregroundStyle(frame.textColor)
                                .multilineTextAlignment(.center)
                                .padding(space.len(6))
                        }
                    }
                    .frame(width: space.len(rect.width), height: space.len(rect.height))
                    .clipped()
                    .position(x: space.x(rect.midX), y: space.y(rect.midY))
                }
            }

            // Manual: magenta button above the gate
            if !manualPages.isEmpty {
                Button { showingManual = true } label: {
                    Text("Manual")
                        .font(VitaFont.font(space.len(14)))
                        .foregroundStyle(.white)
                        .frame(width: space.len(70), height: space.len(70))
                        .background(RoundedRectangle(cornerRadius: space.len(12), style: .continuous).fill(Color(red: 202 / 255, green: 0, blue: 106 / 255)))
                }
                .position(x: space.x(gate.midX), y: space.y(544 - 505 + 35))
            }

            // Gate with the Start button
            Button(action: pressStart) {
                ZStack(alignment: .bottom) {
                    Group {
                        if let picture = image(template.gate) ?? image("startup.png") {
                            Image(uiImage: picture).resizable()
                        } else {
                            ZStack {
                                Color(red: 47 / 255, green: 51 / 255, blue: 50 / 255)
                                if let icon = app.icon {
                                    Image(uiImage: icon).resizable().frame(width: space.len(94), height: space.len(94))
                                        .padding(.bottom, space.len(32))
                                }
                            }
                        }
                    }
                    .frame(width: space.len(280), height: space.len(158))

                    Text("Start")
                        .font(VitaFont.font(space.len(17), bold: true))
                        .foregroundStyle(.white)
                        .frame(width: space.len(120), height: space.len(32))
                        .background(RoundedRectangle(cornerRadius: space.len(10), style: .continuous).fill(Color(red: 20 / 255, green: 168 / 255, blue: 222 / 255)))
                        .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                        .padding(.bottom, space.len(8))
                }
                .frame(width: space.len(280), height: space.len(158))
                .clipShape(RoundedRectangle(cornerRadius: space.len(10), style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: space.len(10), style: .continuous)
                    .strokeBorder(Color(white: 0.75), lineWidth: max(space.len(3), 1.5)))
                .shadow(color: .black.opacity(0.45), radius: space.len(10), y: space.len(4))
            }
            .buttonStyle(VitaPressStyle())
            .contextMenu {
                Button(action: pressStart) { Label("Start", systemImage: "play.fill") }
                Button(action: info) { Label("Information", systemImage: "info.circle") }
                Button(action: settings) { Label("Game settings, patches & saves", systemImage: "slider.horizontal.3") }
            }
            .position(x: space.x(gate.midX), y: space.y(gate.midY))

            // Options (the Vita's triangle menu): information and the game's settings
            Menu {
                Button(action: info) { Label("Information", systemImage: "info.circle") }
                Button(action: settings) { Label("Game settings, patches & saves", systemImage: "slider.horizontal.3") }
            } label: {
                Image(systemName: "triangle")
                    .font(.system(size: space.len(18), weight: .bold))
                    .foregroundStyle(Color(red: 0.4, green: 0.9, blue: 0.75))
                    .frame(width: space.len(46), height: space.len(46))
                    .background(Circle().fill(.black.opacity(0.45)))
            }
            .position(x: space.x(30), y: space.y(510))

            if starting {
                VitaStartZoom(app: app, from: gate, space: space)
            }
        }
        .frame(width: space.size.width, height: space.size.height)
        .onAppear { template = LiveAreaTemplate.load(contents: contents) }
        .fullScreenCover(isPresented: $showingManual) { VitaManual(pages: manualPages) }
    }

    private func pressStart() {
        guard !starting else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        withAnimation(.easeOut(duration: 0.1)) { starting = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
            start()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { starting = false }
        }
    }
}

struct VitaPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .brightness(configuration.isPressed ? -0.08 : 0)
            .animation(.spring(response: 0.22, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// Start pressed: the screen darkens and the game's picture (pic0) grows out of the gate to fill the screen
private struct VitaStartZoom: View {
    let app: GameApp
    let from: CGRect
    let space: VitaSpace
    @State private var grown = false

    private var picture: UIImage? {
        UIImage(contentsOfFile: (app.path as NSString).appendingPathComponent("sce_sys/pic0.png"))
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity(grown ? 0.85 : 0)
            Group {
                if let picture {
                    Image(uiImage: picture).resizable().scaledToFill()
                } else {
                    Color.black
                }
            }
            .frame(width: grown ? space.size.width : space.len(from.width), height: grown ? space.size.height : space.len(from.height))
            .clipShape(RoundedRectangle(cornerRadius: grown ? 0 : space.len(10), style: .continuous))
            .position(x: grown ? space.size.width / 2 : space.x(from.midX), y: grown ? space.size.height / 2 : space.y(from.midY))
            .opacity(grown ? 1 : 0.2)
        }
        .frame(width: space.size.width, height: space.size.height)
        .onAppear { withAnimation(.easeInOut(duration: 0.6)) { grown = true } }
        .allowsHitTesting(false)
    }
}

// MARK: - Manual

/// The game's manual (sce_sys/manual/*.png), one page at a time
struct VitaManual: View {
    let pages: [String]
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0

    static func pages(appPath: String) -> [String] {
        let folder = (appPath as NSString).appendingPathComponent("sce_sys/manual")
        let fm = FileManager.default
        var files = ((try? fm.contentsOfDirectory(atPath: folder)) ?? []).filter { $0.lowercased().hasSuffix(".png") }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        var base = folder
        if files.isEmpty, let sub = ((try? fm.contentsOfDirectory(atPath: folder)) ?? []).sorted().first(where: {
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: (folder as NSString).appendingPathComponent($0), isDirectory: &isDir) && isDir.boolValue
        }) {
            base = (folder as NSString).appendingPathComponent(sub)
            files = ((try? fm.contentsOfDirectory(atPath: base)) ?? []).filter { $0.lowercased().hasSuffix(".png") }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }
        return files.map { (base as NSString).appendingPathComponent($0) }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(Array(pages.enumerated()), id: \.offset) { i, path in
                    Group {
                        if let image = UIImage(contentsOfFile: path) {
                            Image(uiImage: image).resizable().scaledToFit()
                        }
                    }
                    .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.headline).foregroundStyle(.white).padding(10).background(Circle().fill(.black.opacity(0.5)))
                }
                Spacer()
                Text("\(index + 1) / \(pages.count)").font(VitaFont.font(15)).foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 6).background(Capsule().fill(.black.opacity(0.5)))
                Spacer()
                Color.clear.frame(width: 40, height: 40)
            }
            .padding()
        }
        .statusBarHidden(true)
    }
}

// MARK: - Search

/// Search: type a few letters and the games that match appear as bubbles
struct VitaSearch: View {
    let apps: [GameApp]
    let space: VitaSpace
    let close: () -> Void
    let open: (GameApp) -> Void
    @State private var query = ""
    @FocusState private var focused: Bool

    private var results: [GameApp] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        return apps.filter { $0.title.localizedCaseInsensitiveContains(q) || $0.titleId.localizedCaseInsensitiveContains(q) }
            .sorted { $0.title < $1.title }
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.6).ignoresSafeArea().onTapGesture(perform: close)
            VStack(spacing: space.len(18)) {
                HStack(spacing: space.len(12)) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search games", text: $query)
                        .font(VitaFont.font(space.len(22)))
                        .focused($focused)
                        .submitLabel(.search)
                        .autocorrectionDisabled()
                    Button(action: close) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                }
                .padding(.horizontal, space.len(18))
                .frame(height: space.len(52))
                .background(Capsule().fill(Color(white: 0.95)))
                .foregroundStyle(.black)
                .frame(maxWidth: space.len(620))

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: space.len(22)) {
                        ForEach(results) { app in
                            Button { open(app) } label: { VitaBubbleView(item: .game(app), space: space) }.buttonStyle(VitaBubbleButtonStyle())
                        }
                    }
                    .padding(.horizontal, space.len(40))
                }
                if !query.isEmpty && results.isEmpty {
                    Text("No games found").font(VitaFont.font(space.len(18))).foregroundStyle(.white.opacity(0.8))
                }
            }
            .padding(.top, space.len(44))
        }
        .onAppear { focused = true }
    }
}


// MARK: - System panels

enum VitaPanelKind: Hashable {
    case contentManager, settings, themes, music, notifications

    var title: String {
        switch self {
        case .contentManager: "Content Manager"
        case .settings: "Settings"
        case .themes: "Themes"
        case .music: "Music"
        case .notifications: "Notifications"
        }
    }

    var symbol: String {
        switch self {
        case .contentManager: "arrow.down.circle"
        case .settings: "gearshape.fill"
        case .themes: "paintpalette.fill"
        case .music: "music.note"
        case .notifications: "bell.fill"
        }
    }
}

/// A system application of the home screen, drawn like the Vita's own: a blue title bar with the application's
/// bubble, white text on a dark glass page. It is peeled away from the top-right corner like a LiveArea.
struct VitaPanel: View {
    let kind: VitaPanelKind
    let space: VitaSpace
    @ObservedObject var model: LibraryModel
    let notices: [String]
    let close: () -> Void
    let importFiles: () -> Void
    let importFolder: () -> Void
    let enterZrif: () -> Void

    @AppStorage("v3k.vitaHome.theme") private var themeId = VitaTheme.defaultId
    @AppStorage("v3k.vitaMusic") private var vitaMusic = false
    @AppStorage("v3k.musicEnabled") private var musicEnabled = true
    @AppStorage("v3k.vitaHome") private var vitaHome = true

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.06, green: 0.12, blue: 0.24), Color(red: 0.02, green: 0.04, blue: 0.1)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Title bar, below the information bar
                HStack(spacing: space.len(14)) {
                    Image(systemName: kind.symbol)
                        .font(.system(size: space.len(24), weight: .semibold))
                        .frame(width: space.len(44), height: space.len(44))
                        .background(Circle().fill(LinearGradient(colors: [Color(red: 0.3, green: 0.7, blue: 1), Color(red: 0.05, green: 0.4, blue: 0.8)], startPoint: .top, endPoint: .bottom)))
                        .overlay(Circle().strokeBorder(.white.opacity(0.85), lineWidth: 1.5))
                    Text(kind.title).font(VitaFont.font(space.len(28), bold: true))
                    Spacer()
                    Button(action: close) {
                        Image(systemName: "xmark").font(.system(size: space.len(18), weight: .bold))
                            .frame(width: space.len(44), height: space.len(44))
                            .background(Circle().fill(.white.opacity(0.14)))
                    }
                    .padding(.trailing, space.len(60 + max(space.inset, 0)))
                }
                .foregroundStyle(.white)
                .padding(.leading, space.len(40 + max(space.inset, 0)))
                .padding(.top, space.len(44))
                .padding(.bottom, space.len(12))

                Divider().overlay(.white.opacity(0.25))

                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: space.size.width, height: space.size.height)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var content: some View {
        switch kind {
        case .settings:
            // All the settings of the app, inside the panel (its own Done button is not needed here)
            SettingsView(onDone: close).environmentObject(model)
                .padding(.horizontal, space.len(max(space.inset, 0)))
        case .contentManager: contentManager
        case .themes: themes
        case .music: music
        case .notifications: notifications
        }
    }

    private func row(_ symbol: String, _ title: String, _ detail: String, tint: Color = Color(red: 0.3, green: 0.7, blue: 1), action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: space.len(16)) {
                Image(systemName: symbol).font(.system(size: space.len(24)))
                    .foregroundStyle(tint).frame(width: space.len(40))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(VitaFont.font(space.len(22), bold: true))
                    Text(detail).font(VitaFont.font(space.len(15))).foregroundStyle(.white.opacity(0.65))
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.white.opacity(0.4))
            }
            .padding(.horizontal, space.len(20)).padding(.vertical, space.len(12))
            .background(RoundedRectangle(cornerRadius: space.len(12), style: .continuous).fill(.white.opacity(0.08)))
            .contentShape(Rectangle())
        }
        .buttonStyle(VitaPressStyle())
    }

    private var contentManager: some View {
        ScrollView {
            VStack(spacing: space.len(12)) {
                row("doc.badge.plus", "Install from files", "VPK, ZIP, PKG, PUP firmware, work.bin or .rif licenses", action: importFiles)
                row("folder.badge.plus", "Install a game folder", "A decrypted game folder or an existing Vita3K folder", action: importFolder)
                row("key.horizontal.fill", "Enter a zRIF key", "For a PKG that needs its license key", action: enterZrif)
                HStack(spacing: space.len(10)) {
                    stat("gamecontroller.fill", "\(model.apps.count)", "games")
                    stat("cpu", model.hasFirmware ? "Installed" : "Missing", "firmware")
                    stat("textformat", model.hasFonts ? "Installed" : "Missing", "fonts")
                }
                .padding(.top, space.len(6))
            }
            .padding(.horizontal, space.len(40)).padding(.vertical, space.len(18))
            .frame(maxWidth: space.len(820))
            .frame(maxWidth: .infinity)
        }
    }

    private func stat(_ symbol: String, _ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Image(systemName: symbol).foregroundStyle(Color(red: 0.3, green: 0.7, blue: 1))
            Text(value).font(VitaFont.font(space.len(20), bold: true))
            Text(label).font(VitaFont.font(space.len(14))).foregroundStyle(.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity).padding(.vertical, space.len(12))
        .background(RoundedRectangle(cornerRadius: space.len(12), style: .continuous).fill(.white.opacity(0.06)))
        .foregroundStyle(.white)
    }

    private var themes: some View {
        let all = VitaTheme.installed()
        return ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: space.len(220)), spacing: space.len(16))], spacing: space.len(16)) {
                ForEach(all) { theme in
                    Button {
                        themeId = theme.id
                        MenuMusic.shared.settingsChanged()
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    } label: {
                        VStack(spacing: space.len(8)) {
                            ZStack {
                                if theme.id == VitaTheme.defaultId {
                                    LinearGradient(colors: [Color(red: 0.36, green: 0.62, blue: 0.86), Color(red: 0.03, green: 0.1, blue: 0.3)], startPoint: .topLeading, endPoint: .bottomTrailing)
                                } else if let path = theme.wallpapers.first, let image = VitaFirmware.image(atPath: path) {
                                    Image(uiImage: image).resizable().scaledToFill()
                                } else {
                                    Color.gray
                                }
                            }
                            .frame(height: space.len(110))
                            .clipShape(RoundedRectangle(cornerRadius: space.len(10), style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: space.len(10), style: .continuous)
                                .strokeBorder(themeId == theme.id ? Color(red: 0.3, green: 0.8, blue: 1) : .white.opacity(0.2), lineWidth: themeId == theme.id ? 3 : 1))
                            Text(theme.name).font(VitaFont.font(space.len(16))).foregroundStyle(.white).lineLimit(1)
                        }
                    }
                    .buttonStyle(VitaPressStyle())
                }
            }
            .padding(space.len(40))
            if all.count == 1 {
                Text("Themes you install in Vita3K (ux0/theme) show up here too.")
                    .font(VitaFont.font(space.len(15))).foregroundStyle(.white.opacity(0.6))
                    .padding(.bottom, space.len(20))
            }
        }
    }

    private var music: some View {
        VStack(spacing: space.len(14)) {
            row(musicEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill", "Menu music", musicEnabled ? "On" : "Off") {
                musicEnabled.toggle()
                MenuMusic.shared.settingsChanged()
            }
            row("opticaldisc", "Use the PS Vita home music", vitaMusic ? "On: the firmware's own music" : "Off: songs made on your device") {
                vitaMusic.toggle()
                MenuMusic.shared.settingsChanged()
            }
            row("forward.fill", "Next song", "Skip to a new generated song") { MenuMusic.shared.skip() }
        }
        .padding(.horizontal, space.len(40)).padding(.vertical, space.len(18))
        .frame(maxWidth: space.len(820))
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var notifications: some View {
        ScrollView {
            VStack(spacing: space.len(10)) {
                row("square.grid.2x2.fill", "Back to the normal library", "Turn the PS Vita home screen off (Settings > Appearance turns it on again)") {
                    vitaHome = false
                }
                if notices.isEmpty {
                    Text("No new notifications").font(VitaFont.font(space.len(18))).foregroundStyle(.white.opacity(0.7))
                        .padding(.top, space.len(60))
                }
                ForEach(Array(notices.enumerated()), id: \.offset) { _, text in
                    HStack(spacing: space.len(14)) {
                        Image(systemName: "bell.fill").foregroundStyle(Color(red: 1, green: 0.75, blue: 0.3))
                        Text(text).font(VitaFont.font(space.len(17))).foregroundStyle(.white)
                        Spacer()
                    }
                    .padding(space.len(16))
                    .background(RoundedRectangle(cornerRadius: space.len(12), style: .continuous).fill(.white.opacity(0.08)))
                }
            }
            .padding(.horizontal, space.len(40)).padding(.vertical, space.len(18))
            .frame(maxWidth: space.len(820))
            .frame(maxWidth: .infinity)
        }
    }
}
