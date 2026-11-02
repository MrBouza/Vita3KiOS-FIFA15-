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

private let controlTint = UIColor.white

final class PadButtonView: UIView {
    let button: Int32
    private let label = UILabel()
    private let feedback = UIImpactFeedbackGenerator(style: .light)

    init(button: Int32, title: String, fontSize: CGFloat = 18) {
        self.button = button
        super.init(frame: .zero)
        backgroundColor = UIColor.white.withAlphaComponent(0.14)
        layer.borderColor = UIColor.white.withAlphaComponent(0.35).cgColor
        layer.borderWidth = 1.5
        label.text = title
        label.textColor = controlTint
        label.font = .systemFont(ofSize: fontSize, weight: .bold)
        label.textAlignment = .center
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds
        layer.cornerRadius = min(bounds.width, bounds.height) / 2
    }

    private func setPressed(_ pressed: Bool) {
        v3k_pad_set_button(button, pressed)
        backgroundColor = UIColor.white.withAlphaComponent(pressed ? 0.45 : 0.14)
        if pressed { feedback.impactOccurred() }
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
        backgroundColor = UIColor.white.withAlphaComponent(0.10)
        layer.borderColor = UIColor.white.withAlphaComponent(0.30).cgColor
        layer.borderWidth = 1.5
        knob.backgroundColor = UIColor.white.withAlphaComponent(0.45)
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

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isMultipleTouchEnabled = true
        controls.forEach { addSubview($0) }

        exitButton.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        exitButton.tintColor = UIColor.white.withAlphaComponent(0.7)
        exitButton.addTarget(self, action: #selector(exitTapped), for: .touchUpInside)
        addSubview(exitButton)

        hideButton.tintColor = UIColor.white.withAlphaComponent(0.7)
        hideButton.addTarget(self, action: #selector(hideTapped), for: .touchUpInside)
        addSubview(hideButton)

        controls.forEach { $0.alpha = opacity }
        applyVisibility()

        let center = NotificationCenter.default
        center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in
            self?.controllerConnected = !GCController.controllers().isEmpty
        }
        center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            self?.controllerConnected = !GCController.controllers().isEmpty
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
        let alert = UIAlertController(title: "Quit game?", message: "Unsaved progress will be lost.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Quit", style: .destructive) { _ in
            v3k_pad_release_all()
            v3k_pad_request_exit()
        })
        window?.rootViewController?.present(alert, animated: true)
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
