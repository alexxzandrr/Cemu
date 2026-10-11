import SwiftUI

/// On-screen Wii U GamePad controls, drawn over the full-screen game view (Phase 2E). Each control writes straight
/// into Cemu's input state through CemuBridge (WiiPadTouchController → VPADController).
///
/// Layout follows the GamePad: shoulders in the top corners, left stick above the D-pad, right stick above X/A/B/Y,
/// − and + at the bottom centre. The whole layer is drawn at a user-chosen opacity; touches that miss a control fall
/// through to the game view (GamePad touchscreen).

private let fillIdle = Color.black.opacity(0.28)
private let fillPressed = Color.white.opacity(0.55)
private let stroke = Color.white.opacity(0.7)

/// A button that is pressed while a finger is on it.
struct PadButton: View {
    let title: String
    let button: WiiPadButton
    var width: CGFloat = 52
    var height: CGFloat = 52
    var circle = true

    @State private var pressed = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: circle ? min(width, height) / 2 : min(width, height) * 0.22)
        Text(title)
            .font(.system(size: min(width, height) * 0.38, weight: .semibold))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.6), radius: 1)
            .frame(width: width, height: height)
            .background(shape.fill(pressed ? fillPressed : fillIdle))
            .overlay(shape.stroke(stroke, lineWidth: 1.5))
            .contentShape(shape)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in set(true) }
                    .onEnded { _ in set(false) }
            )
            // hiding the controls mid-press must not leave the button held
            .onChange(of: isEnabled) { enabled in if !enabled { set(false) } }
            .onDisappear { set(false) }
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
    @State private var active = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let radius = diameter / 2
        ZStack {
            Circle().fill(fillIdle)
            Circle().stroke(stroke, lineWidth: 1.5)
            Circle()
                .fill(active ? fillPressed : Color.white.opacity(0.35))
                .overlay(Circle().stroke(stroke, lineWidth: 1))
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
                    active = true
                    knob = CGSize(width: dx * radius * 0.6, height: dy * radius * 0.6)
                    CemuBridge.shared.setGamePadStick(stick, x: Float(dx), y: Float(-dy)) // Wii U: up is positive
                }
                .onEnded { _ in release() }
        )
        .onChange(of: isEnabled) { enabled in if !enabled { release() } }
        .onDisappear { release() }
    }

    private func release() {
        active = false
        knob = .zero
        CemuBridge.shared.setGamePadStick(stick, x: 0, y: 0)
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

/// Look of the overlay toolbar's translucent capsules (not GamePad buttons).
private struct ToolbarLabel: View {
    let systemImage: String
    var label: String? = nil
    var highlighted = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
            if let label { Text(label) }
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(Capsule().fill(highlighted ? Color.white.opacity(0.35) : Color.black.opacity(0.4)))
        .overlay(Capsule().stroke(Color.white.opacity(0.4), lineWidth: 1))
    }
}

private struct ToolbarButton: View {
    let systemImage: String
    var label: String? = nil
    var highlighted = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ToolbarLabel(systemImage: systemImage, label: label, highlighted: highlighted)
        }
        .buttonStyle(.plain)
    }
}

/// Full-screen overlay shown while a title runs: GamePad controls plus a small toolbar
/// (GamePad/TV screen, tilt recenter, control opacity, hide controls).
struct GamePadOverlay: View {
    @AppStorage("WiiPadControlsOpacity") private var controlsOpacity = 0.55
    // not persisted: a title always starts with the controls shown
    @State private var controlsHidden = false
    @State private var showGamePadScreen = false

    private static let opacityChoices: [Double] = [0.3, 0.55, 0.8, 1.0]

    var body: some View {
        GeometryReader { geo in
            // sizes are tuned for an 11" iPad (820 pt short side) and scaled for other screens
            let s = min(max(min(geo.size.width, geo.size.height) / 820, 0.8), 1.3)
            ZStack {
                // Hidden controls stay in the view tree (invisible, disabled, not hit-testable) so the overlay's
                // layout over the game view is the same in both states; only visibility changes.
                controls(scale: s)
                    .opacity(controlsHidden ? 0 : controlsOpacity)
                    .allowsHitTesting(!controlsHidden)
                    .disabled(controlsHidden)
                VStack {
                    toolbar
                    Spacer()
                }
            }
            .padding(.horizontal, 20 * s)
            .padding(.vertical, 14 * s)
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    @ViewBuilder
    private func controls(scale s: CGFloat) -> some View {
        let shoulderW = 76 * s, shoulderH = 46 * s
        let stick = 136 * s
        let diamond = 50 * s

        VStack(spacing: 0) {
            HStack(spacing: 10 * s) {
                PadButton(title: "ZL", button: .zl, width: shoulderW, height: shoulderH, circle: false)
                PadButton(title: "L", button: .l, width: shoulderW, height: shoulderH, circle: false)
                Spacer()
                PadButton(title: "R", button: .r, width: shoulderW, height: shoulderH, circle: false)
                PadButton(title: "ZR", button: .zr, width: shoulderW, height: shoulderH, circle: false)
            }
            Spacer()
            HStack(alignment: .bottom, spacing: 0) {
                VStack(alignment: .leading, spacing: 18 * s) {
                    PadStick(stick: 0, diameter: stick)
                    PadDiamond(top: ("▲", .up), left: ("◀", .left), right: ("▶", .right), bottom: ("▼", .down),
                               size: diamond, circle: false)
                        .padding(.leading, 40 * s)
                }
                Spacer()
                HStack(spacing: 28 * s) {
                    PadButton(title: "−", button: .minus, width: 48 * s, height: 36 * s)
                    PadButton(title: "+", button: .plus, width: 48 * s, height: 36 * s)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 18 * s) {
                    PadStick(stick: 1, diameter: stick)
                    PadDiamond(top: ("X", .x), left: ("Y", .y), right: ("A", .a), bottom: ("B", .b), size: diamond)
                        .padding(.trailing, 40 * s)
                }
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            // kept in place while hidden (invisible, not hit-testable), so Show sits exactly where Hide was
            HStack(spacing: 8) {
                ToolbarButton(systemImage: "rectangle.on.rectangle",
                              label: showGamePadScreen ? "TV view" : "Pad view",
                              highlighted: showGamePadScreen) {
                    showGamePadScreen.toggle()
                    CemuBridge.shared.setGamePadButton(.screen, pressed: showGamePadScreen)
                    CemuBridge.shared.log("GamePad screen in game view: \(showGamePadScreen ? "on" : "off")")
                }
                // tilt controls use the iPad's gyroscope; this makes the current pose the starting pose again
                ToolbarButton(systemImage: "gyroscope", label: "Recenter") {
                    CemuBridge.shared.recenterMotion()
                }
                Menu {
                    Picker("Control opacity", selection: $controlsOpacity) {
                        ForEach(Self.opacityChoices, id: \.self) { choice in
                            Text("\(Int(choice * 100)) %").tag(choice)
                        }
                    }
                } label: {
                    ToolbarLabel(systemImage: "circle.lefthalf.filled", label: "\(Int(controlsOpacity * 100)) %")
                }
            }
            .opacity(controlsHidden ? 0 : 1)
            .allowsHitTesting(!controlsHidden)

            ToolbarButton(systemImage: controlsHidden ? "gamecontroller" : "eye.slash",
                          label: controlsHidden ? "Show controls" : "Hide") {
                controlsHidden.toggle()
                CemuBridge.shared.log("on-screen controls \(controlsHidden ? "hidden" : "shown")")
            }
            .contentShape(Capsule())
        }
    }
}
