import SwiftUI
import UIKit

/// Output resolution choices (CemuBridge.outputScale). The game itself still renders at its own resolution.
enum OutputResolution: String, CaseIterable, Identifiable {
    case native, high, balanced, battery
    var id: String { rawValue }
    var scale: Float {
        switch self {
        case .native: return 1.0
        case .high: return 0.75
        case .balanced: return 0.6
        case .battery: return 0.45
        }
    }
    var title: String {
        switch self {
        case .native: return "Native"
        case .high: return "High"
        case .balanced: return "Balanced"
        case .battery: return "Battery"
        }
    }
    var summary: String {
        switch self {
        case .native: return "Sharpest picture, most heat."
        case .high: return "Nearly as sharp, noticeably cooler. Recommended."
        case .balanced: return "Softer edges, cooler and longer battery life."
        case .battery: return "Softest picture, coolest running."
        }
    }
    static let storageKey = "WiiPadOutputResolution"
    static var stored: OutputResolution {
        OutputResolution(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .high
    }
}

/// Everything about the running game that the in-game UI shows or controls: pause state (several reasons can hold it),
/// frame rate, heat, and the output resolution, which drops automatically while iOS reports the device as hot.
@MainActor
final class GameSession: ObservableObject {
    static let shared = GameSession()

    @Published private(set) var paused = false
    @Published private(set) var fps: Double = 0
    @Published private(set) var thermal: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    @Published private(set) var thermalLimited = false
    @Published var menuOpen = false {
        didSet { if menuOpen != oldValue { setPause(menuOpen, reason: "menu") } }
    }
    /// the library entry being played (name and icon for the menus)
    @Published var current: LibraryEntry?

    private var pauseReasons = Set<String>()
    private var timer: Timer?
    private var lastFrames = 0
    private var lastSample = Date()
    private var started = false

    private init() {}

    /// Starts once a title runs: frame-rate sampling, heat observation, output resolution.
    func start() {
        guard !started else { return }
        started = true
        lastFrames = Int(CemuBridge.shared.presentedFrameCount)
        lastSample = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
        NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            Task { @MainActor in self?.thermalChanged() }
        }
        thermalChanged()
    }

    /// A pause holder: "menu", "background" (app not active), "closed" (iPhone Duo folded shut). The game runs while
    /// no reason holds it.
    func setPause(_ on: Bool, reason: String) {
        if on { pauseReasons.insert(reason) } else { pauseReasons.remove(reason) }
        let shouldPause = !pauseReasons.isEmpty
        guard shouldPause != paused else { return }
        if shouldPause {
            if CemuBridge.shared.pauseTitle(pauseReasons.sorted().joined(separator: ", ")) { paused = true }
        } else {
            if CemuBridge.shared.resumeTitle(reason) { paused = false }
        }
    }

    /// The Resume button: clears every pause reason except the app not being active.
    func resumeAll() {
        let keep = pauseReasons.contains("background")
        pauseReasons = keep ? ["background"] : []
        if menuOpen { menuOpen = false } // didSet removes "menu" and resumes
        setPause(false, reason: "resume button")
    }

    /// Output resolution from the setting, lowered while the device is hot if "Cool down automatically" is on.
    func applyOutputScale() {
        let chosen = OutputResolution.stored.scale
        var scale = chosen
        let auto = UserDefaults.standard.object(forKey: "WiiPadAutoCooling") as? Bool ?? true
        if auto {
            switch thermal {
            case .serious: scale = min(scale, OutputResolution.balanced.scale)
            case .critical: scale = min(scale, OutputResolution.battery.scale)
            default: break
            }
        }
        thermalLimited = scale < chosen
        CemuBridge.shared.outputScale = scale
    }

    private func thermalChanged() {
        let state = ProcessInfo.processInfo.thermalState
        if state != thermal || !started {
            CemuBridge.shared.log("heat: thermal state \(Self.describe(state))")
        }
        thermal = state
        applyOutputScale()
    }

    private func sample() {
        let now = Date()
        let frames = Int(CemuBridge.shared.presentedFrameCount)
        let dt = now.timeIntervalSince(lastSample)
        if dt > 0.2 {
            fps = paused ? 0 : Double(frames &- lastFrames) / dt
        }
        lastFrames = frames
        lastSample = now
    }

    static func describe(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "cool"
        case .fair: return "warm"
        case .serious: return "hot"
        case .critical: return "very hot"
        @unknown default: return "unknown"
        }
    }

    var heatTint: Color {
        switch thermal {
        case .nominal: return Theme.good
        case .fair: return Theme.accent
        case .serious: return Theme.warn
        default: return Theme.hot
        }
    }
}

// MARK: - In-game top bar

/// Small in-game bar: menu (pauses), the TV/GamePad swap in single-screen layouts, and the optional FPS + heat readout.
/// Flat translucent fills only (no blur over the running game).
struct InGameBar: View {
    @ObservedObject private var session = GameSession.shared
    let showSwap: Bool
    @Binding var showGamePadScreen: Bool
    @AppStorage("WiiPadShowStats") private var showStats = false

    var body: some View {
        HStack(spacing: 8) {
            barButton(systemImage: "line.3.horizontal") {
                Haptics.select()
                session.menuOpen = true
            }
            .accessibilityLabel("Menu")
            if showSwap {
                barButton(systemImage: showGamePadScreen ? "tv" : "ipad.landscape",
                          highlighted: showGamePadScreen) {
                    Haptics.select()
                    showGamePadScreen.toggle()
                    CemuBridge.shared.setGamePadButton(.screen, pressed: showGamePadScreen)
                    CemuBridge.shared.log("GamePad screen in game view: \(showGamePadScreen ? "on" : "off")")
                }
                .accessibilityLabel(showGamePadScreen ? "Show TV screen" : "Show GamePad screen")
            }
            Spacer(minLength: 0)
            if showStats {
                stats
            }
        }
    }

    private func barButton(systemImage: String, highlighted: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(Circle().fill(highlighted ? Theme.accent.opacity(0.55) : Color.black.opacity(0.38)))
                .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var stats: some View {
        HStack(spacing: 8) {
            Text("\(Int(session.fps.rounded())) FPS")
                .monospacedDigit()
            Circle()
                .fill(session.heatTint)
                .frame(width: 8, height: 8)
            Text(GameSession.describe(session.thermal))
        }
        .font(Theme.rounded(12, .bold))
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(Capsule().fill(Color.black.opacity(0.45)))
    }
}

// MARK: - Pause menu

/// Shown while the game is paused from the menu button: resume, screens, resolution, controls, settings, quit.
/// The game is paused, so blur materials are fine here.
struct QuickMenu: View {
    @ObservedObject private var session = GameSession.shared
    @Binding var screens: ScreensSetting
    @Binding var controlsHidden: Bool
    let onSettings: () -> Void

    @AppStorage(OutputResolution.storageKey) private var resolution: OutputResolution = .high
    @AppStorage("WiiPadShowStats") private var showStats = false
    @State private var confirmQuit = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .onTapGesture { session.resumeAll() }

            ScrollView {
                VStack(spacing: 16) {
                    header
                    Button {
                        Haptics.press()
                        session.resumeAll()
                    } label: {
                        Label("Resume", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(AccentButtonStyle())

                    VStack(alignment: .leading, spacing: 8) {
                        sectionTitle("Screens")
                        Picker("Screens", selection: $screens) {
                            ForEach(ScreensSetting.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        sectionTitle(session.thermalLimited ? "Resolution · lowered while hot" : "Resolution")
                        Picker("Resolution", selection: $resolution) {
                            ForEach(OutputResolution.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: resolution) { _ in session.applyOutputScale() }
                    }

                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                        tile(controlsHidden ? "Show controls" : "Hide controls",
                             systemImage: controlsHidden ? "gamecontroller.fill" : "eye.slash.fill") {
                            controlsHidden.toggle()
                            CemuBridge.shared.log("on-screen controls \(controlsHidden ? "hidden" : "shown")")
                        }
                        tile("Recenter tilt", systemImage: "gyroscope") {
                            CemuBridge.shared.recenterMotion()
                        }
                        tile(showStats ? "Hide FPS" : "Show FPS", systemImage: "speedometer") {
                            showStats.toggle()
                        }
                        tile("Settings", systemImage: "gearshape.fill", action: onSettings)
                    }

                    Button(role: .destructive) {
                        confirmQuit = true
                    } label: {
                        Label("Quit WiiPad", systemImage: "xmark.circle.fill")
                            .foregroundStyle(Theme.hot)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(GlassButtonStyle())
                }
                .padding(22)
                .frame(maxWidth: 440)
                .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(.ultraThinMaterial))
                .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(Color.white.opacity(0.14), lineWidth: 1))
                .padding(20)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
        }
        .confirmationDialog("Quit WiiPad?", isPresented: $confirmQuit, titleVisibility: .visible) {
            Button("Quit", role: .destructive) {
                CemuBridge.shared.log("quit from the in-game menu")
                exit(0)
            }
        } message: {
            Text("Progress since your last in-game save will be lost. Cemu can't unload a game, so WiiPad closes; open it again to play something else.")
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Group {
                if let entry = session.current, let icon = LibraryStore.shared.icon(for: entry) {
                    Image(uiImage: icon).resizable().interpolation(.high).scaledToFill()
                } else {
                    ZStack {
                        Theme.accentGradient.opacity(0.4)
                        Image(systemName: "gamecontroller.fill").foregroundStyle(.white)
                    }
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(session.current?.name ?? "Game")
                    .font(Theme.rounded(18, .bold))
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text("Paused")
                    Circle().fill(session.heatTint).frame(width: 7, height: 7)
                    Text(GameSession.describe(session.thermal))
                }
                .font(Theme.rounded(13, .medium))
                .foregroundStyle(Theme.secondaryText)
            }
            Spacer(minLength: 0)
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(Theme.rounded(11, .bold))
            .foregroundStyle(Theme.secondaryText)
    }

    private func tile(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.select()
            action()
        } label: {
            VStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.accentGradient)
                Text(title)
                    .font(Theme.rounded(13, .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.10), lineWidth: 1))
        }
        .buttonStyle(CardPressStyle())
    }
}

/// Shown when the game was paused by the system (app in the background, iPhone Duo closed) rather than the menu.
struct PausedBanner: View {
    @ObservedObject private var session = GameSession.shared

    var body: some View {
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: "pause.circle.fill")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(Theme.accentGradient)
                Text("Paused")
                    .font(Theme.rounded(22, .bold))
                Button {
                    Haptics.press()
                    session.resumeAll()
                } label: {
                    Label("Resume", systemImage: "play.fill")
                }
                .buttonStyle(AccentButtonStyle())
            }
            .padding(28)
            .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(.ultraThinMaterial))
        }
    }
}
