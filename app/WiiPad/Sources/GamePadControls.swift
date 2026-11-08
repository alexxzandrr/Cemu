import SwiftUI

/// On-screen Wii U GamePad controls. Each control writes straight into Cemu's input state through CemuBridge
/// (WiiPadTouchController → VPADController).
///
/// Look: flat translucent dark fills with a thin light rim (no blur: the game keeps rendering underneath), accent
/// colour and a slight shrink while pressed, a light haptic tick on press (Settings › Controls).

let fillIdle = Color.black.opacity(0.32)
let fillPressed = Theme.accent.opacity(0.6)
let stroke = Color.white.opacity(0.38)

enum PadShape { case circle, capsule, rounded }

/// A button that is held while a finger is on it.
struct PadButton: View {
    var title: String? = nil
    var systemImage: String? = nil
    let button: WiiPadButton
    var width: CGFloat = 52
    var height: CGFloat = 52
    var shape: PadShape = .circle
    /// no own background/rim (part of a shared shape, e.g. the D-pad cross)
    var chromeless = false

    @State private var pressed = false
    @Environment(\.isEnabled) private var isEnabled

    init(title: String? = nil, systemImage: String? = nil, button: WiiPadButton, width: CGFloat = 52, height: CGFloat = 52,
         shape: PadShape = .circle, chromeless: Bool = false) {
        self.title = title
        self.systemImage = systemImage
        self.button = button
        self.width = width
        self.height = height
        self.shape = shape
        self.chromeless = chromeless
    }

    /// Earlier call style: `circle: false` means a rounded rectangle.
    init(title: String, button: WiiPadButton, width: CGFloat = 52, height: CGFloat = 52, circle: Bool) {
        self.init(title: title, button: button, width: width, height: height, shape: circle ? .circle : .rounded)
    }

    var body: some View {
        let s = min(width, height)
        let outline = RoundedRectangle(cornerRadius: shape == .circle || shape == .capsule ? s / 2 : s * 0.28,
                                       style: .continuous)
        Group {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: s * 0.36, weight: .heavy))
            } else {
                Text(title ?? "")
                    .font(Theme.rounded(s * 0.4, .bold))
            }
        }
        .foregroundStyle(.white.opacity(pressed ? 1 : 0.92))
        .shadow(color: .black.opacity(0.5), radius: 1)
        .frame(width: width, height: height)
        .background(chromeless ? nil : outline.fill(pressed ? fillPressed : fillIdle))
        .overlay(chromeless ? nil : outline.stroke(pressed ? Theme.accent : stroke, lineWidth: 1.5))
        .background(chromeless && pressed ? outline.fill(fillPressed) : nil)
        .contentShape(outline)
        .scaleEffect(pressed ? 0.9 : 1)
        .animation(.spring(response: 0.18, dampingFraction: 0.6), value: pressed)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in set(true) }
                .onEnded { _ in set(false) }
        )
        // hiding the controls mid-press must not leave the button held
        .onChange(of: isEnabled) { enabled in if !enabled { set(false) } }
        .onDisappear { set(false) }
        .accessibilityLabel(title ?? systemImage ?? "")
    }

    private func set(_ down: Bool) {
        guard down != pressed else { return }
        pressed = down
        if down { Haptics.press() }
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
            Circle().stroke(active ? Theme.accent : stroke, lineWidth: 1.5)
            Circle()
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
                .frame(width: diameter * 0.62, height: diameter * 0.62)
            Circle()
                .fill(LinearGradient(colors: [.white.opacity(active ? 0.95 : 0.75), .white.opacity(active ? 0.7 : 0.45)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(Circle().stroke(active ? Theme.accent : Color.white.opacity(0.6), lineWidth: active ? 2 : 1))
                .shadow(color: .black.opacity(0.45), radius: 6, y: 3)
                .frame(width: diameter * 0.44, height: diameter * 0.44)
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
                    if !active { Haptics.press() }
                    active = true
                    knob = CGSize(width: dx * radius * 0.56, height: dy * radius * 0.56)
                    CemuBridge.shared.setGamePadStick(stick, x: Float(dx), y: Float(-dy)) // Wii U: up is positive
                }
                .onEnded { _ in release() }
        )
        .onChange(of: isEnabled) { enabled in if !enabled { release() } }
        .onDisappear { release() }
        .accessibilityLabel(stick == 0 ? "Left stick" : "Right stick")
    }

    private func release() {
        active = false
        withAnimation(.spring(response: 0.2, dampingFraction: 0.65)) { knob = .zero }
        CemuBridge.shared.setGamePadStick(stick, x: 0, y: 0)
    }
}

/// Plus-shaped outline for the D-pad.
struct CrossShape: Shape {
    func path(in rect: CGRect) -> Path {
        // one outline (no inner lines where the arms meet)
        let t = rect.width / 3
        let x0 = rect.minX, y0 = rect.minY
        let points: [CGPoint] = [
            CGPoint(x: x0 + t, y: y0), CGPoint(x: x0 + 2 * t, y: y0),
            CGPoint(x: x0 + 2 * t, y: y0 + t), CGPoint(x: x0 + 3 * t, y: y0 + t),
            CGPoint(x: x0 + 3 * t, y: y0 + 2 * t), CGPoint(x: x0 + 2 * t, y: y0 + 2 * t),
            CGPoint(x: x0 + 2 * t, y: y0 + 3 * t), CGPoint(x: x0 + t, y: y0 + 3 * t),
            CGPoint(x: x0 + t, y: y0 + 2 * t), CGPoint(x: x0, y: y0 + 2 * t),
            CGPoint(x: x0, y: y0 + t), CGPoint(x: x0 + t, y: y0 + t),
        ]
        var path = Path()
        path.addLines(points)
        path.closeSubpath()
        return path
    }
}

/// A joined D-pad: one cross with four press areas.
struct PadDPad: View {
    var size: CGFloat = 44 // one arm

    var body: some View {
        let full = size * 3
        ZStack {
            CrossShape().fill(fillIdle)
            CrossShape().stroke(stroke, lineWidth: 1.5)
            VStack(spacing: 0) {
                arm("chevron.up", .up)
                HStack(spacing: 0) {
                    arm("chevron.left", .left)
                    Color.clear.frame(width: size, height: size)
                    arm("chevron.right", .right)
                }
                arm("chevron.down", .down)
            }
        }
        .frame(width: full, height: full)
    }

    private func arm(_ image: String, _ button: WiiPadButton) -> some View {
        PadButton(systemImage: image, button: button, width: size, height: size, shape: .rounded, chromeless: true)
    }
}

/// Four buttons in a diamond (X/A/B/Y).
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

/// Full-screen overlay while a title runs: the in-game bar (menu, TV/GamePad swap, FPS) and, unless the stacked
/// dual-screen layout draws them around the GamePad screen, the GamePad controls over the game.
struct GamePadOverlay: View {
    /// false: bar only (the stacked dual-screen layout draws the controls around the GamePad screen instead)
    var showControls = true
    /// the TV/GamePad swap only makes sense while the GamePad screen has no view of its own
    var showSwap = true
    /// shared with the dual-screen control panel; not persisted (a title always starts with the controls shown)
    @Binding var controlsHidden: Bool

    @AppStorage("WiiPadControlsOpacity") private var controlsOpacity = 0.55
    @State private var showGamePadScreen = false

    init(showControls: Bool = true, showSwap: Bool = true, controlsHidden: Binding<Bool>) {
        self.showControls = showControls
        self.showSwap = showSwap
        self._controlsHidden = controlsHidden
    }

    var body: some View {
        GeometryReader { geo in
            // sizes are tuned for a 820 pt short side (11" iPad) and scaled for other screens (iPhone Duo ~0.6)
            let s = min(max(min(geo.size.width, geo.size.height) / 820, 0.62), 1.3)
            ZStack {
                // Hidden controls stay in the view tree (invisible, disabled, not hit-testable) so the overlay's
                // layout over the game view is the same in both states; only visibility changes.
                if showControls {
                    controls(scale: s)
                        .opacity(controlsHidden ? 0 : controlsOpacity)
                        .allowsHitTesting(!controlsHidden)
                        .disabled(controlsHidden)
                }
                VStack {
                    InGameBar(showSwap: showSwap, showGamePadScreen: $showGamePadScreen)
                    Spacer()
                }
            }
            .padding(.horizontal, 18 * s)
            .padding(.vertical, 12 * s)
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .onChange(of: showSwap) { available in
            if !available, showGamePadScreen {
                showGamePadScreen = false
                CemuBridge.shared.setGamePadButton(.screen, pressed: false)
            }
        }
    }

    @ViewBuilder
    private func controls(scale s: CGFloat) -> some View {
        let shoulderW = 74 * s, shoulderH = 44 * s
        let stick = 140 * s
        let face = 52 * s

        VStack(spacing: 0) {
            // shoulders sit below the in-game bar
            HStack(spacing: 10 * s) {
                PadButton(title: "ZL", button: .zl, width: shoulderW, height: shoulderH, shape: .capsule)
                PadButton(title: "L", button: .l, width: shoulderW, height: shoulderH, shape: .capsule)
                Spacer()
                PadButton(title: "R", button: .r, width: shoulderW, height: shoulderH, shape: .capsule)
                PadButton(title: "ZR", button: .zr, width: shoulderW, height: shoulderH, shape: .capsule)
            }
            .padding(.top, 50)
            Spacer()
            HStack(alignment: .bottom, spacing: 0) {
                VStack(alignment: .leading, spacing: 16 * s) {
                    PadStick(stick: 0, diameter: stick)
                    PadDPad(size: face * 0.92)
                        .padding(.leading, 34 * s)
                }
                Spacer()
                HStack(spacing: 26 * s) {
                    PadButton(systemImage: "minus", button: .minus, width: 46 * s, height: 32 * s, shape: .capsule)
                    PadButton(systemImage: "plus", button: .plus, width: 46 * s, height: 32 * s, shape: .capsule)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 16 * s) {
                    PadStick(stick: 1, diameter: stick)
                    PadDiamond(top: ("X", .x), left: ("Y", .y), right: ("A", .a), bottom: ("B", .b), size: face)
                        .padding(.trailing, 34 * s)
                }
            }
        }
    }
}
