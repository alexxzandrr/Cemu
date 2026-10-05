import SwiftUI
import UIKit

/// Phase 1B diagnostic screen: initializes the Cemu core and the Metal renderer through CemuBridge
/// and shows each step. Not the real UI.
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
    ]
    @Published var finished = false
    @Published var shutDown = false

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
        CemuBridge.shared.log("boot: finished")
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

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("WiiPad")
                .font(.largeTitle.bold())
            Text("Phase 1B · Cemu core bring-up")
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

            if model.finished {
                Button(model.shutDown ? "Core shut down" : "Shut down core") {
                    model.shutdown()
                }
                .disabled(model.shutDown)
            }

            Text("Logs: Files › On My iPad › WiiPad › WiiPad.log (also log.txt, stdout.txt)")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(40)
        .frame(maxWidth: .infinity, alignment: .leading)
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
