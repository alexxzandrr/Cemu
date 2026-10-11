import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Setup screen (Phase 1B/2A/2B/2E): initializes the Cemu core and the Metal renderer through CemuBridge,
/// lets the user hand a Wii U title from the Files app to Cemu's boot path, then shows the game full screen
/// with translucent on-screen GamePad controls over it. Not the final UI.
@MainActor
final class BootModel: ObservableObject {
    enum StepState { case pending, running, ok, failed }

    struct Step: Identifiable {
        let id: String
        var state: StepState = .pending
        var detail: String = ""
    }

    @Published var steps: [Step] = [
        Step(id: "Cemu core (CemuCommonInit, CafeSystem)"),
        Step(id: "Metal renderer"),
        Step(id: "Wii U title"),
    ]
    @Published var finished = false
    @Published var shutDown = false
    @Published var loadingTitle = false
    @Published var titleLaunched = false
    @Published var savedTitle: URL?

    var readyForTitle: Bool { finished && steps[0].state == .ok && steps[1].state == .ok && !shutDown }

    private var started = false

    func start(hostView: UIView) {
        guard !started else { return }
        started = true
        steps[0].state = .running
        CemuBridge.shared.log("boot: starting core initialization")

        // CemuCommonInit() blocks for a few seconds: run it off the main thread, then hop back.
        Task.detached(priority: .userInitiated) {
            let result: Result<Void, Error>
            do {
                try CemuBridge.shared.initializeCore()
                result = .success(())
            } catch {
                result = .failure(error)
            }
            await self.coreFinished(result, hostView: hostView)
        }
    }

    private func coreFinished(_ result: Result<Void, Error>, hostView: UIView) {
        switch result {
        case .failure(let error):
            steps[0].state = .failed
            steps[0].detail = error.localizedDescription
            finished = true
            return
        case .success:
            steps[0].state = .ok
        }

        steps[1].state = .running
        do {
            try CemuBridge.shared.initializeRenderer(in: hostView)
            // the view may have been laid out again while the core was initializing
            CemuBridge.shared.gameViewDidResize(hostView)
            steps[1].state = .ok
        } catch {
            steps[1].state = .failed
            steps[1].detail = error.localizedDescription
        }
        finished = true
        savedTitle = CemuBridge.shared.savedTitleURL
        CemuBridge.shared.log("boot: finished")
    }

    func pickerOpened(_ kind: String) {
        CemuBridge.shared.log("title picker opened (\(kind))")
    }

    func pickerFinished(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            launchTitle(url)
        case .failure(let error):
            CemuBridge.shared.log("title picker failed: \(error.localizedDescription)")
        }
    }

    /// Title identification and mounting block for a moment: run off the main thread.
    func launchTitle(_ url: URL) {
        guard !loadingTitle, !titleLaunched else { return }
        loadingTitle = true
        steps[2].state = .running
        steps[2].detail = url.lastPathComponent
        Task.detached(priority: .userInitiated) {
            let result: Result<String, Error>
            do {
                result = .success(try CemuBridge.shared.launchTitle(at: url))
            } catch {
                result = .failure(error)
            }
            await self.titleFinished(result)
        }
    }

    private func titleFinished(_ result: Result<String, Error>) {
        loadingTitle = false
        switch result {
        case .success(let name):
            steps[2].state = .ok
            steps[2].detail = "\(name): handed to Cemu. Progress is logged to WiiPad.log."
            titleLaunched = true
        case .failure(let error):
            steps[2].state = .failed
            steps[2].detail = error.localizedDescription
        }
    }

    func shutdown() {
        CemuBridge.shared.shutdown()
        shutDown = true
    }
}

/// UIView that hosts the CAMetalLayer created by the Cemu renderer (the layer's own view ignores touches).
/// Touches on it are forwarded to Cemu as GamePad touchscreen input (Phase 2B), normalized to [0, 1].
/// It fills the screen; size changes (rotation, Split View) are passed to Cemu (Phase 2E).
final class GameSurfaceView: UIView {
    override func layoutSubviews() {
        super.layoutSubviews()
        CemuBridge.shared.gameViewDidResize(self)
    }

    private func forward(_ touches: Set<UITouch>, down: Bool) {
        guard let touch = touches.first, bounds.width > 0, bounds.height > 0 else { return }
        let p = touch.location(in: self)
        CemuBridge.shared.setGameViewTouchDown(down, x: Float(p.x / bounds.width), y: Float(p.y / bounds.height))
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { forward(touches, down: true) }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { forward(touches, down: true) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { forward(touches, down: false) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { forward(touches, down: false) }
}

struct MetalHostView: UIViewRepresentable {
    let onReady: @MainActor (UIView) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = GameSurfaceView()
        view.backgroundColor = .black
        // after SwiftUI has laid the view out, so it has a size
        Task { @MainActor in onReady(view) }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

struct ContentView: View {
    @StateObject private var model = BootModel()
    @State private var showImporter = false
    @State private var importerTypes: [UTType] = [.folder]
    @State private var multicoreCPU = CemuBridge.shared.multicoreCPU
    @State private var asyncShaderCompile = CemuBridge.shared.asyncShaderCompile

    var body: some View {
        // The Metal host view is always the first child of this ZStack, full screen, so SwiftUI never recreates it
        // (that would detach Cemu's CAMetalLayer). Before launch the setup panel covers it (nothing is rendered yet);
        // while a title runs the GamePad overlay sits on top and touches that miss a control reach the game view.
        ZStack {
            MetalHostView { view in model.start(hostView: view) }
                .ignoresSafeArea()

            if model.titleLaunched {
                GamePadOverlay()
            } else {
                setupPanel
            }
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .statusBarHidden(model.titleLaunched)
        .persistentSystemOverlays(model.titleLaunched ? .hidden : .automatic)
        // edge swipes (Control Center, Notification Center, Home) need a second swipe while playing
        .defersSystemGestures(on: model.titleLaunched ? .all : [])
        .fileImporter(isPresented: $showImporter, allowedContentTypes: importerTypes) { result in
            model.pickerFinished(result)
        }
    }

    private var setupPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("WiiPad")
                    .font(.largeTitle.bold())
                Text("Phase 3 · JIT recompiler")
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 12) {
                    ForEach(model.steps) { step in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            icon(for: step.state)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(step.id)
                                if !step.detail.isEmpty {
                                    Text(step.detail)
                                        .font(.footnote)
                                        .foregroundStyle(step.state == .failed ? .red : .secondary)
                                }
                            }
                        }
                    }
                }

                if model.readyForTitle {
                    HStack(spacing: 12) {
                        Button("Choose title folder…") {
                            model.pickerOpened("folder")
                            importerTypes = [.folder]
                            showImporter = true
                        }
                        Button("Choose title file…") {
                            model.pickerOpened("file")
                            importerTypes = [.item]
                            showImporter = true
                        }
                        if let saved = model.savedTitle {
                            Button("Reopen \(saved.lastPathComponent)") {
                                CemuBridge.shared.log("title selected from saved bookmark")
                                model.launchTitle(saved)
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.loadingTitle)
                    Text("Folder: an extracted title's root (with code, content and meta). File: .wua, .wud, .wux, .wuhb or a homebrew .rpx. Disc images also need keys.txt in WiiPad's folder.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Toggle("Multi-core (experimental: three host threads for the three Wii U cores; recompiler or interpreter)", isOn: $multicoreCPU)
                        .font(.footnote)
                        .onChange(of: multicoreCPU) { enabled in
                            CemuBridge.shared.multicoreCPU = enabled
                        }
                    Toggle("Async shader compilation (on: smoother, but objects can be missing until their shaders compile; off: brief hitches, nothing missing)", isOn: $asyncShaderCompile)
                        .font(.footnote)
                        .onChange(of: asyncShaderCompile) { enabled in
                            CemuBridge.shared.asyncShaderCompile = enabled
                        }
                    Text("Compiled shaders are kept in Files › On My iPad › WiiPad › shaderCache and precompiled on the loading screen of the next launch.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("The game runs full screen with translucent GamePad controls. Touches that miss a control are GamePad touchscreen input. To stop a title, close WiiPad from the app switcher.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Divider()
                JITSection()
                Divider()

                if model.finished {
                    Button(model.shutDown ? "Core shut down" : "Shut down core") {
                        model.shutdown()
                    }
                    .disabled(model.shutDown || model.loadingTitle)
                }

                Text("Logs: Files › On My iPad › WiiPad › WiiPad.log (also log.txt, stdout.txt)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(32)
            .frame(maxWidth: 680, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 20).fill(.ultraThinMaterial))
            .padding(40)
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func icon(for state: BootModel.StepState) -> some View {
        switch state {
        case .pending: Image(systemName: "circle").foregroundStyle(.secondary)
        case .running: ProgressView()
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }
}
