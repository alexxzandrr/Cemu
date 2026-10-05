import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Diagnostic screen (Phase 1B/2A): initializes the Cemu core and the Metal renderer through CemuBridge,
/// then lets the user hand a Wii U title from the Files app to Cemu's boot path. Not the real UI.
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

/// UIView that hosts the CAMetalLayer created by the Cemu renderer.
struct MetalHostView: UIViewRepresentable {
    let onReady: @MainActor (UIView) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
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

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("WiiPad")
                .font(.largeTitle.bold())
            Text("Phase 2A · first Wii U title")
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
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                }
            }

            MetalHostView { view in model.start(hostView: view) }
                .frame(width: 480, height: 270)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            if model.readyForTitle && !model.titleLaunched {
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
            }

            if model.finished && !model.titleLaunched {
                Button(model.shutDown ? "Core shut down" : "Shut down core") {
                    model.shutdown()
                }
                .disabled(model.shutDown || model.loadingTitle)
            } else if model.titleLaunched {
                Text("A title is running. To stop it, close WiiPad from the app switcher.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Text("Logs: Files › On My iPad › WiiPad › WiiPad.log (also log.txt, stdout.txt)")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(40)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: importerTypes) { result in
            model.pickerFinished(result)
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
