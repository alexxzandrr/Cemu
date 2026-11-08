import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Engine state: initializes the Cemu core and the Metal renderer through CemuBridge at startup, then hands the chosen
/// game to Cemu's boot path. One game per app session (Cemu can't unload a title).
@MainActor
final class BootModel: ObservableObject {
    enum StepState { case pending, running, ok, failed }

    struct Step: Identifiable {
        let id: String
        var state: StepState = .pending
        var detail: String = ""
    }

    @Published var steps: [Step] = [
        Step(id: "Cemu core"),
        Step(id: "Metal renderer"),
        Step(id: "Game"),
    ]
    @Published var finished = false
    @Published var shutDown = false
    @Published var loadingTitle = false
    @Published var titleLaunched = false
    @Published var titleError: String?

    var readyForTitle: Bool { finished && steps[0].state == .ok && steps[1].state == .ok && !shutDown }
    var coreFailed: Bool { steps[0].state == .failed || steps[1].state == .failed }

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
        // the library reads game names and icons through Cemu's filesystem
        LibraryStore.shared.coreBecameReady(savedTitle: CemuBridge.shared.savedTitleURL)
        CemuBridge.shared.log("boot: finished")
    }

    /// Title identification and mounting block for a moment: run off the main thread.
    func launchTitle(_ url: URL) {
        guard !loadingTitle, !titleLaunched else { return }
        titleError = nil
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
            steps[2].detail = "\(name): running. Progress is logged to WiiPad.log."
            titleLaunched = true
            GameSession.shared.start()
        case .failure(let error):
            steps[2].state = .failed
            steps[2].detail = error.localizedDescription
            titleError = error.localizedDescription
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
    @ObservedObject private var session = GameSession.shared
    @State private var showImporter = false
    @State private var importerTypes: [UTType] = [.folder]
    @State private var showSettings = false
    @AppStorage("WiiPadScreens") private var screens: ScreensSetting = .auto
    @AppStorage("WiiPadControlsOpacity") private var controlsOpacity = 0.55
    @AppStorage("WiiPadPauseWhenClosed") private var pauseWhenClosed = true
    // not persisted: a game always starts with the controls shown
    @State private var controlsHidden = false
    @State private var lastArrangement: String = ""
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            GeometryReader { geo in
                screenLayer(geo)
            }
            .ignoresSafeArea()

            if !model.titleLaunched {
                AppBackground()
                HomeView(model: model, onImport: openImporter, onPlay: play, onSettings: { showSettings = true })
                    .transition(.opacity)
            }
            if model.loadingTitle {
                LaunchView(name: session.current?.name ?? "Starting game",
                           icon: session.current.flatMap { LibraryStore.shared.icon(for: $0) })
                    .transition(.opacity)
            }
            if model.titleLaunched {
                if session.menuOpen {
                    QuickMenu(screens: $screens, controlsHidden: $controlsHidden, onSettings: { showSettings = true })
                        .transition(.opacity)
                } else if session.paused {
                    PausedBanner()
                        .transition(.opacity)
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: model.loadingTitle)
        .animation(.easeInOut(duration: 0.2), value: session.menuOpen)
        .animation(.easeInOut(duration: 0.2), value: session.paused)
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
        .statusBarHidden(model.titleLaunched)
        .persistentSystemOverlays(model.titleLaunched ? .hidden : .automatic)
        // edge swipes (Control Center, Notification Center, Home) need a second swipe while playing
        .defersSystemGestures(on: model.titleLaunched ? .all : [])
        .fileImporter(isPresented: $showImporter, allowedContentTypes: importerTypes) { result in
            switch result {
            case .success(let url): LibraryStore.shared.add(url)
            case .failure(let error): CemuBridge.shared.log("title picker failed: \(error.localizedDescription)")
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(model: model, inGame: model.titleLaunched)
        }
        .onChange(of: scenePhase) { phase in
            // pause while WiiPad isn't the active app (Control Center, app switcher, Home); resume on return
            guard model.titleLaunched else { return }
            session.setPause(phase != .active, reason: "background")
        }
        .modifier(HingePause(enabled: model.titleLaunched && pauseWhenClosed))
    }

    private func openImporter(_ kind: ImportKind) {
        CemuBridge.shared.log("title picker opened (\(kind == .folder ? "folder" : "file"))")
        importerTypes = kind == .folder ? [.folder] : [.item]
        showImporter = true
    }

    private func play(_ entry: LibraryEntry) {
        guard let url = LibraryStore.shared.resolve(entry) else {
            model.titleError = "WiiPad can't find \(entry.name) anymore (moved or deleted?). Remove it and add it again."
            return
        }
        Haptics.press()
        session.current = entry
        LibraryStore.shared.markPlayed(entry)
        CemuBridge.shared.log("library: starting \(entry.name)")
        model.launchTitle(url)
    }

    /// Game screens and controls in full-screen coordinates (the fold's coordinates). The TV view is always the first
    /// child and the GamePad view the third, so SwiftUI never recreates them (that would detach Cemu's CAMetalLayers);
    /// only their frames change. Before a game runs the TV view fills the screen behind the home screen.
    @ViewBuilder
    private func screenLayer(_ geo: GeometryProxy) -> some View {
        let insets = geo.safeAreaInsets
        let arrangement = ScreenArrangement.make(size: geo.size, fold: activeFold(in: geo), setting: screens,
                                                 insets: insets)
        let running = model.titleLaunched
        let tv = running ? arrangement.tv : CGRect(origin: .zero, size: geo.size)
        let pad = running ? arrangement.pad : nil
        let panel = running && arrangement.kind == .stacked ? arrangement.controlsPanel : nil

        ZStack(alignment: .topLeading) {
            MetalHostView { view in model.start(hostView: view) }
                .frame(width: tv.width, height: tv.height)
                .offset(x: tv.minX, y: tv.minY)

            if let panel {
                DualPanelBackground(panel: panel)
            }

            PadHostView(active: pad != nil)
                .frame(width: pad?.width ?? 1, height: pad?.height ?? 1)
                .offset(x: pad?.minX ?? 0, y: pad?.minY ?? 0)
                .opacity(pad != nil ? 1 : 0)
                .allowsHitTesting(pad != nil)

            if running {
                if let panel {
                    DualControlsPanel(panel: panel)
                        .opacity(controlsHidden ? 0 : max(controlsOpacity, 0.75))
                        .allowsHitTesting(!controlsHidden)
                        .disabled(controlsHidden)
                        .offset(x: panel.minX, y: panel.minY)
                    // bar only, over the top of the TV half
                    GamePadOverlay(showControls: false, showSwap: false, controlsHidden: $controlsHidden)
                        .padding(EdgeInsets(top: insets.top, leading: insets.leading, bottom: 0, trailing: insets.trailing))
                        .frame(width: arrangement.tv.width, height: arrangement.tv.height)
                        .offset(x: arrangement.tv.minX, y: arrangement.tv.minY)
                } else {
                    GamePadOverlay(showControls: true, showSwap: arrangement.kind == .single,
                                   controlsHidden: $controlsHidden)
                        .padding(insets)
                        .frame(width: geo.size.width, height: geo.size.height)
                }
            }
        }
        .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        .onChange(of: running ? arrangement.logDescription : "") { description in
            guard !description.isEmpty, description != lastArrangement else { return }
            lastArrangement = description
            CemuBridge.shared.log("screens: \(description)")
        }
    }
}

/// Pauses the game while iPhone Duo is folded shut (like closing a handheld) and resumes when it opens.
/// The hinge API needs the iOS 27.1 SDK; other devices have no hinge and never trigger it.
struct HingePause: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if #available(iOS 27.1, *) {
            content.onHingeChange { _, context in
                let closed = context.hinge?.status == .closed
                GameSession.shared.setPause(enabled && closed, reason: "closed")
            }
        } else {
            content
        }
    }
}
