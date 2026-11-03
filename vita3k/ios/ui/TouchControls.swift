// Vita3K emulator project
// Copyright (C) 2026 Vita3K team
// SPDX-License-Identifier: GPL-2.0-or-later

// On-screen PS Vita controls, drawn over the game window. Each control feeds the SDL virtual gamepad
// in controls/virtual_pad.cpp, which Vita3K sees like a physical controller. Touches that miss every
// control fall through to the game, so the Vita touchscreen keeps working.

import GameController
import UIKit

// SDL_GamepadButton / SDL_GamepadAxis values
private enum Pad {
    static let cross: Int32 = 0, circle: Int32 = 1, square: Int32 = 2, triangle: Int32 = 3
    static let select: Int32 = 4, start: Int32 = 6
    static let l: Int32 = 9, r: Int32 = 10
    static let up: Int32 = 11, down: Int32 = 12, left: Int32 = 13, right: Int32 = 14
    static let leftX: Int32 = 0, leftY: Int32 = 1, rightX: Int32 = 2, rightY: Int32 = 3
}

private func color(_ hex: UInt32) -> UIColor {
    UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

/// Looks of the on-screen controller (Settings > Touch controls > Theme). Only the looks change:
/// a face button always sends the Vita button in its position.
enum ControllerTheme: String, CaseIterable, Identifiable {
    case classic, playstation, xbox, nintendo, neon, minimal

    var id: String { rawValue }

    var name: String {
        switch self {
        case .classic: "Classic"
        case .playstation: "PlayStation colours"
        case .xbox: "Xbox style (A B X Y)"
        case .nintendo: "Nintendo style (A B X Y)"
        case .neon: "Neon"
        case .minimal: "Minimal"
        }
    }

    /// Label and colour of the face button at the top, right, bottom and left
    func face(_ position: Int) -> (String, UIColor) {
        switch self {
        case .classic, .minimal: return [("△", .white), ("○", .white), ("✕", .white), ("□", .white)][position]
        case .playstation: return [("△", color(0x2FD5A0)), ("○", color(0xFF5A5F)), ("✕", color(0x6FA8FF)), ("□", color(0xF48FD0))][position]
        case .xbox: return [("Y", color(0xF7C51E)), ("B", color(0xE2382F)), ("A", color(0x5BB531)), ("X", color(0x2C82E0))][position]
        case .nintendo: return [("X", color(0x3D5BD9)), ("A", color(0xE0303A)), ("B", color(0xF2C230)), ("Y", color(0x3BAA55))][position]
        case .neon: return [("△", color(0x39FFB0)), ("○", color(0xFF3FA4)), ("✕", color(0x3FD8FF)), ("□", color(0xC77DFF))][position]
        }
    }

    /// Colour of the d-pad, shoulders, sticks and small buttons
    var tint: UIColor {
        switch self {
        case .neon: color(0x3FD8FF)
        default: .white
        }
    }

    var filled: Bool { self != .minimal }
    var coloredFill: Bool { self == .playstation || self == .xbox || self == .nintendo }

    static var current: ControllerTheme {
        ControllerTheme(rawValue: UserDefaults.standard.string(forKey: "v3k.controllerTheme") ?? "") ?? .classic
    }
}

/// Touch buttons send whichever physical button the user mapped to their Vita button (Settings >
/// Controller mapping), so an on-screen ✕ is always Vita ✕
enum TouchMapping {
    static var physical: [Int32] = Array(0..<15)

    static func load() {
        if let pointer = v3k_controller_binds_json() {
            let json = String(cString: pointer)
            v3k_free_string(pointer)
            if let data = json.data(using: .utf8), let binds = try? JSONDecoder().decode([Int32].self, from: data), binds.count >= 15 {
                physical = binds
            }
        }
    }

    static func button(for slot: Int32) -> Int32 {
        slot >= 0 && Int(slot) < physical.count ? physical[Int(slot)] : slot
    }
}

/// The colour mixed towards black, for button fills that stay readable on bright backgrounds
func darkened(_ color: UIColor, by brightness: CGFloat) -> UIColor {
    var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
    color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
    return UIColor(red: red * brightness, green: green * brightness, blue: blue * brightness, alpha: alpha)
}

final class PadButtonView: UIView {
    let button: Int32
    private let label = UILabel()
    private let feedback = UIImpactFeedbackGenerator(style: .light)

    private var baseFill = UIColor.black.withAlphaComponent(0.5)
    private var pressedFill = UIColor.white.withAlphaComponent(0.45)
    private let haptics = UserDefaults.standard.object(forKey: "v3k.touchHaptics") as? Bool ?? true

    init(button: Int32, title: String, fontSize: CGFloat = 18, tint: UIColor = .white) {
        self.button = button
        super.init(frame: .zero)
        label.text = title
        label.font = .systemFont(ofSize: fontSize, weight: .bold)
        label.textAlignment = .center
        // A soft dark halo keeps the symbol readable over bright scenes
        label.layer.shadowColor = UIColor.black.cgColor
        label.layer.shadowOpacity = 0.7
        label.layer.shadowRadius = 2
        label.layer.shadowOffset = .zero
        addSubview(label)
        style(color: tint, theme: ControllerTheme.current, faceButton: false)
        layer.borderWidth = 1.5
    }

    /// Applies a controller theme: face buttons get their own colour, the rest the theme tint
    func style(title: String? = nil, color: UIColor, theme: ControllerTheme, faceButton: Bool) {
        if let title { label.text = title }
        label.textColor = color
        // Dark fills on every theme: the controls stay visible over bright scenes (skies, menus)
        if theme.coloredFill && faceButton {
            baseFill = darkened(color, by: 0.3).withAlphaComponent(0.6)
            pressedFill = color.withAlphaComponent(0.7)
        } else {
            baseFill = UIColor.black.withAlphaComponent(theme.filled ? 0.5 : 0.3)
            pressedFill = color.withAlphaComponent(0.5)
        }
        backgroundColor = baseFill
        layer.borderColor = color.withAlphaComponent(theme == .neon ? 0.9 : 0.55).cgColor
        if theme == .neon {
            layer.shadowColor = color.cgColor
            layer.shadowRadius = 6
            layer.shadowOpacity = 0.8
            layer.shadowOffset = .zero
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds
        layer.cornerRadius = min(bounds.width, bounds.height) / 2
    }

    private func setPressed(_ pressed: Bool) {
        v3k_pad_set_button(TouchMapping.button(for: button), pressed)
        backgroundColor = pressed ? pressedFill : baseFill
        if pressed && haptics { feedback.impactOccurred() }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { setPressed(true) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { setPressed(false) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { setPressed(false) }
}

final class StickView: UIView {
    private let xAxis: Int32
    private let yAxis: Int32
    private let knob = UIView()

    init(xAxis: Int32, yAxis: Int32) {
        self.xAxis = xAxis
        self.yAxis = yAxis
        super.init(frame: .zero)
        backgroundColor = UIColor.black.withAlphaComponent(0.4)
        layer.borderColor = UIColor.white.withAlphaComponent(0.45).cgColor
        layer.borderWidth = 1.5
        knob.backgroundColor = UIColor.white.withAlphaComponent(0.55)
        knob.layer.borderColor = UIColor.black.withAlphaComponent(0.4).cgColor
        knob.layer.borderWidth = 1
        knob.isUserInteractionEnabled = false
        addSubview(knob)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.width / 2
        let size = bounds.width * 0.45
        knob.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        knob.layer.cornerRadius = size / 2
        if knob.center == .zero { knob.center = CGPoint(x: bounds.midX, y: bounds.midY) }
    }

    private func update(_ touch: UITouch) {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = bounds.width / 2
        var dx = touch.location(in: self).x - center.x
        var dy = touch.location(in: self).y - center.y
        let length = sqrt(dx * dx + dy * dy)
        if length > radius {
            dx *= radius / length
            dy *= radius / length
        }
        knob.center = CGPoint(x: center.x + dx, y: center.y + dy)
        v3k_pad_set_axis(xAxis, Float(dx / radius))
        v3k_pad_set_axis(yAxis, Float(dy / radius))
    }

    private func reset() {
        knob.center = CGPoint(x: bounds.midX, y: bounds.midY)
        v3k_pad_set_axis(xAxis, 0)
        v3k_pad_set_axis(yAxis, 0)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { if let t = touches.first { update(t) } }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { if let t = touches.first { update(t) } }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { reset() }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { reset() }
}

final class ControlsOverlayView: UIView {
    private let l = PadButtonView(button: Pad.l, title: "L")
    private let r = PadButtonView(button: Pad.r, title: "R")
    private let up = PadButtonView(button: Pad.up, title: "▲", fontSize: 16)
    private let down = PadButtonView(button: Pad.down, title: "▼", fontSize: 16)
    private let left = PadButtonView(button: Pad.left, title: "◀", fontSize: 16)
    private let right = PadButtonView(button: Pad.right, title: "▶", fontSize: 16)
    private let triangle = PadButtonView(button: Pad.triangle, title: "△", fontSize: 22)
    private let circle = PadButtonView(button: Pad.circle, title: "○", fontSize: 22)
    private let cross = PadButtonView(button: Pad.cross, title: "✕", fontSize: 20)
    private let square = PadButtonView(button: Pad.square, title: "□", fontSize: 22)
    private let select = PadButtonView(button: Pad.select, title: "SELECT", fontSize: 10)
    private let start = PadButtonView(button: Pad.start, title: "START", fontSize: 10)
    private let leftStick = StickView(xAxis: Pad.leftX, yAxis: Pad.leftY)
    private let rightStick = StickView(xAxis: Pad.rightX, yAxis: Pad.rightY)
    private let exitButton = UIButton(type: .system)
    private let hideButton = UIButton(type: .system)

    private var controls: [UIView] {
        [l, r, up, down, left, right, triangle, circle, cross, square, select, start, leftStick, rightStick]
    }

    private var controlsHidden = UserDefaults.standard.bool(forKey: "v3k.touchControlsHidden") {
        didSet {
            UserDefaults.standard.set(controlsHidden, forKey: "v3k.touchControlsHidden")
            applyVisibility()
        }
    }

    // Settings > Touch controls
    private let opacity = CGFloat(UserDefaults.standard.object(forKey: "v3k.touchOpacity") as? Double ?? 0.6)
    private let scale = CGFloat(UserDefaults.standard.object(forKey: "v3k.touchScale") as? Double ?? 1.0)
    private let hideWithController = UserDefaults.standard.object(forKey: "v3k.touchHideWithController") as? Bool ?? true
    private var controllerConnected = !GCController.controllers().isEmpty {
        didSet { applyVisibility() }
    }
    // Controller shortcut: hold Select + Start to open the game menu (polled, so SDL keeps its input handlers)
    private var shortcutTimer: Timer?
    private var shortcutHeldSince: Date?
    private weak var menuAlert: UIAlertController?
    // Settings › Performance overlay; stays visible when the controls are hidden
    private let hud: PerformanceHUDView? = HUDSettings.enabled ? PerformanceHUDView(frame: .zero) : nil

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isMultipleTouchEnabled = true
        controls.forEach { addSubview($0) }

        exitButton.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        exitButton.tintColor = UIColor.white.withAlphaComponent(0.85)
        exitButton.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        exitButton.addTarget(self, action: #selector(exitTapped), for: .touchUpInside)
        addSubview(exitButton)

        hideButton.tintColor = UIColor.white.withAlphaComponent(0.85)
        hideButton.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        hideButton.addTarget(self, action: #selector(hideTapped), for: .touchUpInside)
        addSubview(hideButton)
        if let hud { addSubview(hud) }

        // Controller theme
        let theme = ControllerTheme.current
        for (position, button) in [triangle, circle, cross, square].enumerated() {
            let (title, faceColor) = theme.face(position)
            button.style(title: title, color: faceColor, theme: theme, faceButton: true)
        }
        for button in [l, r, up, down, left, right, select, start] {
            button.style(color: theme.tint, theme: theme, faceButton: false)
        }
        for stick in [leftStick, rightStick] {
            stick.layer.borderColor = theme.tint.withAlphaComponent(0.35).cgColor
        }

        controls.forEach { $0.alpha = opacity }
        applyVisibility()

        let center = NotificationCenter.default
        center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in
            self?.controllerConnected = !GCController.controllers().isEmpty
        }
        center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            self?.controllerConnected = !GCController.controllers().isEmpty
        }

        shortcutTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.checkControllerShortcut()
        }
    }

    deinit {
        shortcutTimer?.invalidate()
    }

    private func checkControllerShortcut() {
        let held = GCController.controllers().contains { controller in
            guard let pad = controller.extendedGamepad else { return false }
            return pad.buttonMenu.isPressed && (pad.buttonOptions?.isPressed ?? false)
        }
        guard held else {
            shortcutHeldSince = nil
            return
        }
        if let since = shortcutHeldSince {
            if Date().timeIntervalSince(since) > 1.2 && menuAlert == nil {
                shortcutHeldSince = .distantFuture // fire once per hold
                v3k_pad_release_all()
                showMenu(fromController: true)
            }
        } else {
            shortcutHeldSince = Date()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // Touches that miss every control go to the game (Vita touchscreen)
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }

    private func applyVisibility() {
        let hidden = controlsHidden || (hideWithController && controllerConnected)
        controls.forEach { $0.isHidden = hidden }
        hideButton.setImage(UIImage(systemName: controlsHidden ? "gamecontroller" : "eye.slash"), for: .normal)
        if hidden { v3k_pad_release_all() }
    }

    @objc private func exitTapped() {
        showMenu(fromController: false)
    }

    func showMenu(fromController: Bool) {
        guard menuAlert == nil, let root = window?.rootViewController else { return }
        let alert = UIAlertController(title: "Quit game?", message: fromController
            ? "Unsaved progress will be lost.\n(Press the controller's Home/PS button, or hold Select + Start, to open this menu.)"
            : "Unsaved progress will be lost.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Quit", style: .destructive) { _ in
            v3k_pad_release_all()
            v3k_pad_request_exit()
        })
        alert.addAction(UIAlertAction(title: controlsHidden ? "Show touch controls" : "Hide touch controls", style: .default) { [weak self] _ in
            self?.controlsHidden.toggle()
        })
        alert.addAction(UIAlertAction(title: "Keep playing", style: .cancel))
        menuAlert = alert
        (root.presentedViewController ?? root).present(alert, animated: true)
    }

    @objc private func hideTapped() {
        controlsHidden.toggle()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let area = bounds.inset(by: safeAreaInsets).insetBy(dx: 12, dy: 10)
        let unit = min(max(min(area.width, area.height) * 0.13, 40), 64) * scale // button size

        // Shoulder buttons
        l.frame = CGRect(x: area.minX, y: area.minY, width: unit * 1.9, height: unit * 0.8)
        r.frame = CGRect(x: area.maxX - unit * 1.9, y: area.minY, width: unit * 1.9, height: unit * 0.8)
        l.layer.cornerRadius = unit * 0.4
        r.layer.cornerRadius = unit * 0.4

        // D-pad (left) and face buttons (right), vertically centred
        let clusterSize = unit * 3
        let clusterY = area.midY - clusterSize / 2 - unit * 0.4
        layoutDiamond(top: up, right: right, bottom: down, left: left,
                      in: CGRect(x: area.minX, y: clusterY, width: clusterSize, height: clusterSize), unit: unit)
        layoutDiamond(top: triangle, right: circle, bottom: cross, left: square,
                      in: CGRect(x: area.maxX - clusterSize, y: clusterY, width: clusterSize, height: clusterSize), unit: unit)

        // Sticks below the clusters, pulled towards the centre
        let stickSize = unit * 2
        leftStick.frame = CGRect(x: area.minX + clusterSize * 0.75, y: area.maxY - stickSize, width: stickSize, height: stickSize)
        rightStick.frame = CGRect(x: area.maxX - clusterSize * 0.75 - stickSize, y: area.maxY - stickSize, width: stickSize, height: stickSize)

        // Select / Start, bottom centre
        let smallWidth = unit * 1.4, smallHeight = unit * 0.55
        select.frame = CGRect(x: area.midX - smallWidth - 8, y: area.maxY - smallHeight, width: smallWidth, height: smallHeight)
        start.frame = CGRect(x: area.midX + 8, y: area.maxY - smallHeight, width: smallWidth, height: smallHeight)

        // Quit and show/hide, top centre
        exitButton.frame = CGRect(x: area.midX - 44, y: area.minY, width: 36, height: 36)
        hideButton.frame = CGRect(x: area.midX + 8, y: area.minY, width: 36, height: 36)
        exitButton.layer.cornerRadius = 18
        hideButton.layer.cornerRadius = 18

        if let hud {
            let size = hud.sizeThatFits(bounds.size)
            // Below the shoulder buttons at the top, above the screen edge at the bottom
            let top = l.frame.maxY + 8
            let bottom = area.maxY - size.height
            let origin: CGPoint
            switch hud.corner {
            case 1: origin = CGPoint(x: area.maxX - size.width, y: top)
            case 2: origin = CGPoint(x: area.minX, y: bottom)
            case 3: origin = CGPoint(x: area.maxX - size.width, y: bottom)
            default: origin = CGPoint(x: area.minX, y: top)
            }
            hud.frame = CGRect(origin: origin, size: size)
        }
    }

    private func layoutDiamond(top: UIView, right: UIView, bottom: UIView, left: UIView, in rect: CGRect, unit: CGFloat) {
        top.frame = CGRect(x: rect.midX - unit / 2, y: rect.minY, width: unit, height: unit)
        bottom.frame = CGRect(x: rect.midX - unit / 2, y: rect.maxY - unit, width: unit, height: unit)
        left.frame = CGRect(x: rect.minX, y: rect.midY - unit / 2, width: unit, height: unit)
        right.frame = CGRect(x: rect.maxX - unit, y: rect.midY - unit / 2, width: unit, height: unit)
    }
}

/// Root of the controls window: landscape like the game, and transparent to touches it doesn't use
final class ControlsViewController: UIViewController {
    override func loadView() {
        view = ControlsOverlayView(frame: UIScreen.main.bounds)
    }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
}

/// A window above the game's: touches that miss every control fall through to the game window
final class PassthroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return (hit === self || hit === rootViewController?.view) ? nil : hit
    }
}

@MainActor
enum ControlsHost {
    static var window: UIWindow?

    static func attach(over gameWindow: UIWindow) {
        detach()
        TouchMapping.load()
        let overlay: PassthroughWindow
        if let scene = gameWindow.windowScene {
            overlay = PassthroughWindow(windowScene: scene)
        } else {
            overlay = PassthroughWindow(frame: gameWindow.bounds)
        }
        overlay.windowLevel = gameWindow.windowLevel + 1
        overlay.backgroundColor = .clear
        overlay.rootViewController = ControlsViewController()
        overlay.isHidden = false // shown but not key: the game window keeps keyboard/gamepad focus
        window = overlay
    }

    static func detach() {
        window?.isHidden = true
        window = nil
    }
}

// Called from C++ (main_ios.cpp) when the game window is created and destroyed
@_cdecl("v3k_controls_attach")
public func v3kControlsAttach(_ uiWindow: UnsafeMutableRawPointer?) {
    guard let uiWindow else { return }
    let window = Unmanaged<UIWindow>.fromOpaque(uiWindow).takeUnretainedValue()
    MainActor.assumeIsolated { ControlsHost.attach(over: window) }
}

@_cdecl("v3k_controls_detach")
public func v3kControlsDetach() {
    MainActor.assumeIsolated { ControlsHost.detach() }
}

/// Controller guide / PS button pressed in game
@_cdecl("v3k_controls_show_menu")
public func v3kControlsShowMenu() {
    MainActor.assumeIsolated {
        v3k_pad_release_all()
        (ControlsHost.window?.rootViewController?.view as? ControlsOverlayView)?.showMenu(fromController: true)
    }
}
