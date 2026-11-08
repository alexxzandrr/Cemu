import SwiftUI
import UIKit

/// WiiPad's look: near-black background, one cyan → violet accent, rounded type, translucent cards.
/// In-game views use flat translucent fills only: blur materials over a 60 fps Metal view make the GPU re-blur the game
/// every frame (heat). Materials are used only on screens shown while the game is paused or not running.
enum Theme {
    static let background = Color(red: 0.035, green: 0.04, blue: 0.065)
    static let accent = Color(red: 0.27, green: 0.80, blue: 1.0)
    static let accent2 = Color(red: 0.56, green: 0.44, blue: 1.0)
    static let accentGradient = LinearGradient(colors: [accent, accent2], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let card = Color.white.opacity(0.06)
    static let cardStroke = Color.white.opacity(0.10)
    static let secondaryText = Color.white.opacity(0.6)
    static let good = Color(red: 0.35, green: 0.86, blue: 0.55)
    static let warn = Color(red: 1.0, green: 0.72, blue: 0.30)
    static let hot = Color(red: 1.0, green: 0.42, blue: 0.36)

    static func rounded(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

/// Static backdrop for the home screen: dark base with two soft colour glows (drawn once, no animation).
struct AppBackground: View {
    var body: some View {
        ZStack {
            Theme.background
            GeometryReader { geo in
                let d = max(geo.size.width, geo.size.height)
                Circle()
                    .fill(Theme.accent.opacity(0.22))
                    .frame(width: d * 0.7, height: d * 0.7)
                    .blur(radius: d * 0.16)
                    .position(x: geo.size.width * 0.12, y: geo.size.height * 0.05)
                Circle()
                    .fill(Theme.accent2.opacity(0.20))
                    .frame(width: d * 0.6, height: d * 0.6)
                    .blur(radius: d * 0.16)
                    .position(x: geo.size.width * 0.95, y: geo.size.height * 0.9)
            }
        }
        .ignoresSafeArea()
        .drawingGroup()
    }
}

/// Rounded translucent card used across the home screen and menus.
struct CardBackground: ViewModifier {
    var radius: CGFloat = 22
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(Theme.cardStroke, lineWidth: 1))
    }
}

extension View {
    func card(radius: CGFloat = 22) -> some View { modifier(CardBackground(radius: radius)) }
}

/// Capsule status label ("JIT ready", "Engine starting…").
struct StatusPill: View {
    let systemImage: String
    let text: String
    var tint: Color = Theme.good

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
            Text(text)
        }
        .font(Theme.rounded(13, .semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Capsule().fill(tint.opacity(0.14)))
        .overlay(Capsule().stroke(tint.opacity(0.35), lineWidth: 1))
    }
}

/// Prominent gradient button.
struct AccentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.rounded(16, .bold))
            .foregroundStyle(.black.opacity(0.85))
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Capsule().fill(Theme.accentGradient))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Quiet secondary button (translucent capsule).
struct GlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.rounded(15, .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.18 : 0.10)))
            .overlay(Capsule().stroke(Color.white.opacity(0.16), lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Light haptic tick for on-screen controls (toggle in Settings).
enum Haptics {
    private static let impact = UIImpactFeedbackGenerator(style: .light)
    private static let selection = UISelectionFeedbackGenerator()

    static var enabled: Bool {
        UserDefaults.standard.object(forKey: "WiiPadHaptics") as? Bool ?? true
    }

    @MainActor static func press() {
        guard enabled else { return }
        impact.impactOccurred(intensity: 0.7)
    }

    @MainActor static func select() {
        guard enabled else { return }
        selection.selectionChanged()
    }
}
