import SwiftUI

/// Phase 2B: minimal on-screen Wii U GamePad controls. Each control writes straight into Cemu's input state
/// through CemuBridge (WiiPadTouchController → VPADController). Functional, not polished.

private let accent = Color.white.opacity(0.18)
private let accentPressed = Color.white.opacity(0.45)

/// A button that is pressed while a finger is on it.
struct PadButton: View {
    let title: String
    let button: WiiPadButton
    var width: CGFloat = 52
    var height: CGFloat = 52
    var circle = true

    @State private var pressed = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: circle ? min(width, height) / 2 : 10)
        Text(title)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: width, height: height)
            .background(shape.fill(pressed ? accentPressed : accent))
            .overlay(shape.stroke(Color.white.opacity(0.35), lineWidth: 1))
            .contentShape(shape)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in set(true) }
                    .onEnded { _ in set(false) }
            )
    }

    private func set(_ down: Bool) {
        guard down != pressed else { return }
        pressed = down
        CemuBridge.shared.setGamePadButton(button, pressed: down)
    }
}

/// An analog stick: drag inside the circle; released → centered.
struct PadStick: View {
    let stick: Int
    var diameter: CGFloat = 130

    @State private var knob = CGSize.zero

    var body: some View {
        let radius = diameter / 2
        ZStack {
            Circle().fill(accent)
            Circle().stroke(Color.white.opacity(0.35), lineWidth: 1)
            Circle()
                .fill(accentPressed)
                .frame(width: diameter * 0.42, height: diameter * 0.42)
                .offset(knob)
        }
        .frame(width: diameter, height: diameter)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in
                    var dx = (value.location.x - radius) / radius
                    var dy = (value.location.y - radius) / radius
                    let length = (dx * dx + dy * dy).squareRoot()
                    if length > 1 { dx /= length; dy /= length }
                    knob = CGSize(width: dx * radius * 0.6, height: dy * radius * 0.6)
                    CemuBridge.shared.setGamePadStick(stick, x: Float(dx), y: Float(-dy)) // Wii U: up is positive
                }
                .onEnded { _ in
                    knob = .zero
                    CemuBridge.shared.setGamePadStick(stick, x: 0, y: 0)
                }
        )
    }
}

/// Four buttons in a diamond (D-pad, or X/A/B/Y).
struct PadDiamond: View {
    let top: (String, WiiPadButton)
    let left: (String, WiiPadButton)
    let right: (String, WiiPadButton)
    let bottom: (String, WiiPadButton)
    var size: CGFloat = 44
    var circle = true

    var body: some View {
        VStack(spacing: 0) {
            PadButton(title: top.0, button: top.1, width: size, height: size, circle: circle)
            HStack(spacing: size) {
                PadButton(title: left.0, button: left.1, width: size, height: size, circle: circle)
                PadButton(title: right.0, button: right.1, width: size, height: size, circle: circle)
            }
            PadButton(title: bottom.0, button: bottom.1, width: size, height: size, circle: circle)
        }
    }
}

/// Left half of the GamePad: ZL/L, left stick, D-pad, −, and the tilt (motion) recenter button.
struct GamePadLeftPanel: View {
    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                PadButton(title: "ZL", button: .zl, width: 64, height: 44, circle: false)
                PadButton(title: "L", button: .l, width: 64, height: 44, circle: false)
            }
            PadStick(stick: 0)
            PadDiamond(top: ("▲", .up), left: ("◀", .left), right: ("▶", .right), bottom: ("▼", .down), circle: false)
            HStack(spacing: 10) {
                PadButton(title: "−", button: .minus, width: 44, height: 36)
                // tilt controls use the iPad's gyroscope; this makes the current pose the starting pose again
                Button("Recenter") {
                    CemuBridge.shared.recenterMotion()
                }
                .font(.footnote)
                .buttonStyle(.bordered)
            }
        }
    }
}

/// Right half of the GamePad: R/ZR, X/A/B/Y, right stick, +, and the GamePad-screen toggle.
struct GamePadRightPanel: View {
    @State private var showGamePadScreen = false

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                PadButton(title: "R", button: .r, width: 64, height: 44, circle: false)
                PadButton(title: "ZR", button: .zr, width: 64, height: 44, circle: false)
            }
            PadDiamond(top: ("X", .x), left: ("Y", .y), right: ("A", .a), bottom: ("B", .b))
            PadStick(stick: 1)
            HStack(spacing: 10) {
                PadButton(title: "+", button: .plus, width: 44, height: 36)
                Button(showGamePadScreen ? "TV view" : "Pad view") {
                    showGamePadScreen.toggle()
                    CemuBridge.shared.setGamePadButton(.screen, pressed: showGamePadScreen)
                    CemuBridge.shared.log("GamePad screen in game view: \(showGamePadScreen ? "on" : "off")")
                }
                .font(.footnote)
                .buttonStyle(.bordered)
            }
        }
    }
}
