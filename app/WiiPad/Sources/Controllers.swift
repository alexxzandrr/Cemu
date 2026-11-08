import CoreHaptics
import GameController
import QuartzCore
import SwiftUI

/// How face buttons map to the Wii U GamePad.
enum ButtonLayout: String, CaseIterable, Identifiable {
    /// by position, like a Wii U GamePad: right = A, bottom = B, top = X, left = Y (PlayStation: ○ A, ✕ B, △ X, □ Y)
    case position
    /// by the letters printed on Xbox-style controllers: bottom = A, right = B, left = X, top = Y
    case letters
    var id: String { rawValue }
    var title: String {
        switch self {
        case .position: return "Wii U positions"
        case .letters: return "Xbox letters"
        }
    }
}

/// Bluetooth game controllers (DualSense, DualShock 4, Xbox, Switch Pro, MFi) through Apple's GameController framework,
/// mapped onto the emulated Wii U GamePad (CemuBridge controller input, separate from the on-screen controls).
/// Also: the controller's gyroscope as GamePad motion, game rumble on the controller, the PS/Home button for WiiPad's
/// menu and the DualSense touchpad click for the TV/GamePad screen swap.
@MainActor
final class ControllerManager: ObservableObject {
    static let shared = ControllerManager()

    @Published private(set) var controller: GCController?
    @Published private(set) var name = ""
    @Published private(set) var hasMotion = false
    @Published private(set) var batteryText: String?

    static let layoutKey = "WiiPadButtonLayout"
    static let motionKey = "WiiPadControllerMotion"
    static let rumbleKey = "WiiPadControllerRumble"
    static let hideTouchKey = "WiiPadHideTouchWithController"

    private var started = false
    private var rumbleTimer: Timer?
    private var hapticEngine: CHHapticEngine?
    private var rumblePlayer: CHHapticAdvancedPatternPlayer?
    private var rumbling = false
    private var homeHeld = false

    private init() {}

    var connected: Bool { controller != nil }

    func start() {
        guard !started else { return }
        started = true
        let center = NotificationCenter.default
        center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] note in
            guard let c = note.object as? GCController else { return }
            Task { @MainActor in self?.attach(c) }
        }
        center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] note in
            guard let c = note.object as? GCController else { return }
            Task { @MainActor in self?.detach(c) }
        }
        if let first = GCController.controllers().first(where: { $0.extendedGamepad != nil }) {
            attach(first)
        }
        CemuBridge.shared.log("controllers: watching for Bluetooth game controllers")
    }

    private func attach(_ c: GCController) {
        guard c.extendedGamepad != nil else {
            CemuBridge.shared.log("controllers: \(c.vendorName ?? "controller") connected but has no full gamepad profile; ignored")
            return
        }
        if let current = controller, current !== c { return } // one controller drives the GamePad
        controller = c
        name = c.vendorName ?? "Controller"
        c.playerIndex = .index1
        if let pad = c.extendedGamepad {
            // the PS / Home button opens WiiPad's menu instead of the system's game overlay
            pad.buttonHome?.preferredSystemGestureState = .disabled
            pad.valueChangedHandler = { gamepad, _ in
                ControllerManager.apply(gamepad)
                ControllerManager.handleMenuButtons(gamepad)
            }
            ControllerManager.apply(pad)
        }
        updateBattery()
        configureMotion()
        configureRumble()
        CemuBridge.shared.log("controllers: \(name) connected (\(c.productCategory)), motion \(hasMotion ? "yes" : "no"), haptics \(c.haptics != nil ? "yes" : "no")")
        Haptics.select()
    }

    private func detach(_ c: GCController) {
        guard controller === c else { return }
        c.extendedGamepad?.valueChangedHandler = nil
        c.motion?.valueChangedHandler = nil
        CemuBridge.shared.releaseControllerInput()
        CemuBridge.shared.controllerMotionEnabled = false
        stopRumble()
        rumbleTimer?.invalidate()
        rumbleTimer = nil
        hapticEngine?.stop()
        hapticEngine = nil
        rumblePlayer = nil
        CemuBridge.shared.log("controllers: \(name) disconnected")
        controller = nil
        name = ""
        hasMotion = false
        batteryText = nil
        // another one may still be connected
        if let next = GCController.controllers().first(where: { $0 !== c && $0.extendedGamepad != nil }) {
            attach(next)
        }
    }

    // MARK: Buttons and sticks

    /// Writes the whole controller state (called on every change; cheap).
    nonisolated static func apply(_ g: GCExtendedGamepad) {
        let b = CemuBridge.shared
        let letters = UserDefaults.standard.string(forKey: layoutKey) == ButtonLayout.letters.rawValue
        // GCExtendedGamepad names buttons by position: buttonA bottom, buttonB right, buttonX left, buttonY top
        let south = g.buttonA.isPressed, east = g.buttonB.isPressed, west = g.buttonX.isPressed, north = g.buttonY.isPressed
        b.setControllerButton(.a, pressed: letters ? south : east)
        b.setControllerButton(.b, pressed: letters ? east : south)
        b.setControllerButton(.x, pressed: letters ? west : north)
        b.setControllerButton(.y, pressed: letters ? north : west)
        b.setControllerButton(.l, pressed: g.leftShoulder.isPressed)
        b.setControllerButton(.r, pressed: g.rightShoulder.isPressed)
        b.setControllerButton(.zl, pressed: g.leftTrigger.isPressed)
        b.setControllerButton(.zr, pressed: g.rightTrigger.isPressed)
        b.setControllerButton(.plus, pressed: g.buttonMenu.isPressed)
        b.setControllerButton(.minus, pressed: g.buttonOptions?.isPressed ?? false)
        b.setControllerButton(.up, pressed: g.dpad.up.isPressed)
        b.setControllerButton(.down, pressed: g.dpad.down.isPressed)
        b.setControllerButton(.left, pressed: g.dpad.left.isPressed)
        b.setControllerButton(.right, pressed: g.dpad.right.isPressed)
        b.setControllerButton(.stickL, pressed: g.leftThumbstickButton?.isPressed ?? false)
        b.setControllerButton(.stickR, pressed: g.rightThumbstickButton?.isPressed ?? false)
        // DualSense / DualShock 4 touchpad click: GamePad screen in the TV view while held
        var touchpad = false
        if let ds = g as? GCDualSenseGamepad { touchpad = ds.touchpadButton.isPressed }
        else if let ds4 = g as? GCDualShockGamepad { touchpad = ds4.touchpadButton.isPressed }
        b.setControllerButton(.screen, pressed: touchpad)
        b.setControllerStick(0, x: g.leftThumbstick.xAxis.value, y: g.leftThumbstick.yAxis.value)
        b.setControllerStick(1, x: g.rightThumbstick.xAxis.value, y: g.rightThumbstick.yAxis.value)
    }

    /// PS / Home button: opens or closes WiiPad's in-game menu (on release).
    nonisolated static func handleMenuButtons(_ g: GCExtendedGamepad) {
        let pressed = g.buttonHome?.isPressed ?? false
        Task { @MainActor in
            let manager = ControllerManager.shared
            if pressed != manager.homeHeld {
                manager.homeHeld = pressed
                if !pressed {
                    let session = GameSession.shared
                    if session.menuOpen { session.resumeAll() } else { session.menuOpen = true }
                }
            }
        }
    }

    // MARK: Motion

    /// Uses the controller's gyroscope for GamePad motion when it has one and the setting is on.
    func configureMotion() {
        guard let c = controller else { return }
        let wanted = UserDefaults.standard.object(forKey: Self.motionKey) as? Bool ?? true
        guard let motion = c.motion else {
            hasMotion = false
            CemuBridge.shared.controllerMotionEnabled = false
            return
        }
        hasMotion = true
        if !wanted {
            motion.valueChangedHandler = nil
            if motion.sensorsRequireManualActivation { motion.sensorsActive = false }
            CemuBridge.shared.controllerMotionEnabled = false
            return
        }
        if motion.sensorsRequireManualActivation { motion.sensorsActive = true }
        CemuBridge.shared.controllerMotionEnabled = true
        var logged = false
        motion.valueChangedHandler = { m in
            // total acceleration in g: gravity + user acceleration where the controller reports them separately
            let acc: GCAcceleration
            if m.hasGravityAndUserAcceleration {
                acc = GCAcceleration(x: m.gravity.x + m.userAcceleration.x, y: m.gravity.y + m.userAcceleration.y,
                                     z: m.gravity.z + m.userAcceleration.z)
            } else {
                acc = m.acceleration
            }
            let rate = m.rotationRate
            CemuBridge.shared.feedControllerMotionTimestamp(CACurrentMediaTime(), gyroX: rate.x, gyroY: rate.y, gyroZ: rate.z,
                                                            accX: acc.x, accY: acc.y, accZ: acc.z)
            if !logged {
                logged = true
                CemuBridge.shared.log(String(format: "controllers: first motion sample: acc %.2f %.2f %.2f g, gyro %.2f %.2f %.2f rad/s (gravity separate: %@)",
                                             acc.x, acc.y, acc.z, rate.x, rate.y, rate.z, m.hasGravityAndUserAcceleration ? "yes" : "no"))
            }
        }
    }

    // MARK: Rumble

    func configureRumble() {
        rumbleTimer?.invalidate()
        rumbleTimer = nil
        let wanted = UserDefaults.standard.object(forKey: Self.rumbleKey) as? Bool ?? true
        guard wanted, let haptics = controller?.haptics else {
            stopRumble()
            return
        }
        if hapticEngine == nil {
            hapticEngine = haptics.createEngine(withLocality: .default)
            hapticEngine?.isAutoShutdownEnabled = true
            try? hapticEngine?.start()
        }
        // Cemu sets the GamePad's rumble state; follow it at 30 Hz
        rumbleTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.followRumble() }
        }
    }

    private func followRumble() {
        let active = CemuBridge.shared.gamePadRumble && !GameSession.shared.paused
        guard active != rumbling else { return }
        rumbling = active
        if active { startRumble() } else { stopRumble() }
    }

    private func startRumble() {
        guard let engine = hapticEngine else { return }
        do {
            try engine.start()
            let event = CHHapticEvent(eventType: .hapticContinuous,
                                      parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.8),
                                                   CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.3)],
                                      relativeTime: 0, duration: 30)
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try engine.makeAdvancedPlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
            rumblePlayer = player
        } catch {
            CemuBridge.shared.log("controllers: rumble failed: \(error.localizedDescription)")
        }
    }

    private func stopRumble() {
        try? rumblePlayer?.stop(atTime: CHHapticTimeImmediate)
        rumblePlayer = nil
        rumbling = false
    }

    private func updateBattery() {
        guard let battery = controller?.battery else { batteryText = nil; return }
        let percent = Int((battery.batteryLevel * 100).rounded())
        batteryText = battery.batteryState == .charging ? "\(percent) % · charging" : "\(percent) %"
    }

    /// SF Symbol of the controller's button for an on-screen hint, e.g. the PS button.
    var homeSymbol: String {
        controller?.extendedGamepad?.buttonHome?.sfSymbolsName ?? "house.circle"
    }
}

/// Settings section for game controllers.
struct ControllerSettingsSection: View {
    @ObservedObject private var manager = ControllerManager.shared
    @AppStorage(ControllerManager.layoutKey) private var layout: ButtonLayout = .position
    @AppStorage(ControllerManager.motionKey) private var useMotion = true
    @AppStorage(ControllerManager.rumbleKey) private var rumble = true
    @AppStorage(ControllerManager.hideTouchKey) private var hideTouch = true

    var body: some View {
        Section {
            HStack {
                Image(systemName: manager.connected ? "gamecontroller.fill" : "gamecontroller")
                    .foregroundStyle(manager.connected ? Theme.good : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(manager.connected ? manager.name : "No controller connected")
                    if let battery = manager.batteryText {
                        Text("Battery \(battery)").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            Picker("Face buttons", selection: $layout) {
                ForEach(ButtonLayout.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Aim with the controller's motion", isOn: $useMotion)
                .onChange(of: useMotion) { _ in ControllerManager.shared.configureMotion() }
            Toggle("Rumble", isOn: $rumble)
                .onChange(of: rumble) { _ in ControllerManager.shared.configureRumble() }
            Toggle("Hide on-screen controls while connected", isOn: $hideTouch)
        } header: {
            Text("Controller")
        } footer: {
            Text("Pair a DualSense, DualShock 4, Xbox or Switch Pro controller in Settings › Bluetooth (DualSense: hold Create + PS until the light flashes). The PS / Home button opens WiiPad's menu; the touchpad click shows the GamePad screen. Wii U positions: ○ = A, ✕ = B, △ = X, □ = Y.")
        }
    }
}
