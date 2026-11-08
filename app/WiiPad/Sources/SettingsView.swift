import SwiftUI

/// Settings, from the home screen or the in-game menu. Performance and screen options apply right away; CPU and
/// shader options apply to the next game launched.
struct SettingsView: View {
    @ObservedObject var model: BootModel
    let inGame: Bool
    @Environment(\.dismiss) private var dismiss

    @AppStorage(OutputResolution.storageKey) private var resolution: OutputResolution = .high
    @AppStorage("WiiPadAutoCooling") private var autoCooling = true
    @AppStorage("WiiPadShowStats") private var showStats = false
    @AppStorage("WiiPadScreens") private var screens: ScreensSetting = .auto
    @AppStorage("WiiPadPauseWhenClosed") private var pauseWhenClosed = true
    @AppStorage("WiiPadControlsOpacity") private var controlsOpacity = 0.55
    @AppStorage("WiiPadHaptics") private var haptics = true
    @State private var multicoreCPU = CemuBridge.shared.multicoreCPU
    @State private var asyncShaderCompile = CemuBridge.shared.asyncShaderCompile

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Resolution", selection: $resolution) {
                        ForEach(OutputResolution.allCases) { Text($0.title).tag($0) }
                    }
                    .onChange(of: resolution) { _ in GameSession.shared.applyOutputScale() }
                    Toggle("Cool down automatically", isOn: $autoCooling)
                        .onChange(of: autoCooling) { _ in GameSession.shared.applyOutputScale() }
                    Toggle("Show FPS and heat", isOn: $showStats)
                } header: {
                    Text("Performance")
                } footer: {
                    Text("\(resolution.summary) Resolution is the size of the final picture; games still render at their own resolution. Cool down lowers it while iOS reports the device as hot and restores it once it cools.")
                }

                Section {
                    Toggle("Multi-core CPU (experimental)", isOn: $multicoreCPU)
                        .onChange(of: multicoreCPU) { CemuBridge.shared.multicoreCPU = $0 }
                    Toggle("Async shader compilation", isOn: $asyncShaderCompile)
                        .onChange(of: asyncShaderCompile) { CemuBridge.shared.asyncShaderCompile = $0 }
                } header: {
                    Text("Emulation")
                } footer: {
                    Text("Apply to the next game you start. Async shaders: on is smoother, but objects can be missing until their shaders are compiled; off waits for each new shader (short hitches the first time, nothing missing). Compiled shaders are kept and prepared on the loading screen of later launches.")
                }

                Section {
                    Picker("Screens", selection: $screens) {
                        ForEach(ScreensSetting.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("Pause when iPhone Duo is closed", isOn: $pauseWhenClosed)
                } header: {
                    Text("Screens")
                } footer: {
                    Text("Automatic: folded like a laptop, the TV picture is on top and the GamePad screen with the controls below; folded like a book, side by side; flat or closed, the TV picture fills the screen.")
                }

                Section("Controls") {
                    VStack(alignment: .leading) {
                        Text("Opacity \(Int(controlsOpacity * 100)) %")
                        Slider(value: $controlsOpacity, in: 0.2...1.0, step: 0.05)
                    }
                    Toggle("Haptic feedback", isOn: $haptics)
                }

                Section {
                    JITSection()
                } header: {
                    Text("JIT")
                }

                Section {
                    ForEach(model.steps) { step in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(step.id)
                                Spacer()
                                Text(label(for: step.state))
                                    .foregroundStyle(color(for: step.state))
                            }
                            if !step.detail.isEmpty {
                                Text(step.detail)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    LabeledContent("Logs", value: "Files › WiiPad › WiiPad.log")
                    if model.finished && !inGame {
                        Button(model.shutDown ? "Core shut down" : "Shut down core", role: .destructive) {
                            model.shutdown()
                        }
                        .disabled(model.shutDown || model.loadingTitle)
                    }
                } header: {
                    Text("Diagnostics")
                } footer: {
                    Text("WiiPad \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")), based on Cemu (MPL-2.0). Not affiliated with Nintendo.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
    }

    private func label(for state: BootModel.StepState) -> String {
        switch state {
        case .pending: return "Waiting"
        case .running: return "Working…"
        case .ok: return "OK"
        case .failed: return "Failed"
        }
    }

    private func color(for state: BootModel.StepState) -> Color {
        switch state {
        case .ok: return Theme.good
        case .failed: return Theme.hot
        default: return .secondary
        }
    }
}
