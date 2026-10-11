import SwiftUI
import UIKit

/// Phase 3 Gate 0: asks StikDebug to attach to WiiPad (stikdebug://enable-jit with its universal.js script, the
/// iOS 26+ TXM path), waits until the debugger is attached, then runs CemuBridge's JIT test off the main thread.
@MainActor
final class JITTestModel: ObservableObject {
    @Published var status = CemuBridge.shared.jitStatus
    @Published var result: String?
    @Published var busy = false
    @Published var passedAttached = false

    private var waitTask: Task<Void, Never>?

    func refresh() { status = CemuBridge.shared.jitStatus }

    func start() {
        guard !busy else { return }
        result = nil
        if CemuBridge.shared.jitDebuggerAttached {
            run(detach: false)
            return
        }
        busy = true
        var components = URLComponents()
        components.scheme = "stikdebug"
        components.host = "enable-jit"
        components.queryItems = [
            URLQueryItem(name: "bundle-id", value: Bundle.main.bundleIdentifier ?? ""),
            URLQueryItem(name: "pid", value: String(ProcessInfo.processInfo.processIdentifier)),
        ]
        // iOS 26+ on TXM devices (every M-series iPad) needs the script that services the breakpoint protocol
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 {
            components.queryItems?.append(URLQueryItem(name: "script-name", value: "universal.js"))
        }
        guard let url = components.url else { busy = false; return }
        CemuBridge.shared.log("jit: opening \(url.absoluteString)")
        result = "Opening StikDebug… come back to WiiPad once it says JIT is enabled."
        UIApplication.shared.open(url) { opened in
            Task { @MainActor in
                if opened {
                    self.waitForDebugger()
                } else {
                    CemuBridge.shared.log("jit: could not open StikDebug")
                    self.result = "Could not open StikDebug. Is it installed (with its pairing file and LocalDevVPN)?"
                    self.busy = false
                }
            }
        }
    }

    private func waitForDebugger() {
        waitTask?.cancel()
        waitTask = Task { @MainActor in
            // polling pauses while WiiPad is in the background and resumes when you switch back
            for _ in 0..<240 {
                if CemuBridge.shared.jitDebuggerAttached {
                    self.refresh()
                    CemuBridge.shared.log("jit: debugger attached")
                    self.busy = false
                    self.run(detach: false)
                    return
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
                if Task.isCancelled { return }
            }
            CemuBridge.shared.log("jit: no debugger attached after 2 minutes")
            self.result = "StikDebug didn't attach within 2 minutes. Check WiiPad.log and StikDebug's console."
            self.busy = false
            self.refresh()
        }
    }

    func run(detach: Bool) {
        guard !busy else { return }
        busy = true
        result = detach ? "Detaching and testing again…" : "Running the JIT test…"
        Task.detached(priority: .userInitiated) {
            let line = CemuBridge.shared.runJITGate0Detaching(detach)
            await MainActor.run {
                self.result = line
                if line.hasPrefix("Passed") { self.passedAttached = true }
                self.busy = false
                self.refresh()
            }
        }
    }
}

struct JITTestSection: View {
    @StateObject private var model = JITTestModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("JIT test (Phase 3, Gate 0)")
                .font(.headline)
            Text(model.status)
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button(model.busy ? "Working…" : "Enable JIT with StikDebug and test") {
                    model.start()
                }
                .buttonStyle(.bordered)
                .disabled(model.busy)
                if model.passedAttached {
                    Button("Test after detach (may close WiiPad)") {
                        model.run(detach: true)
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.busy)
                }
            }
            if let result = model.result {
                Text(result)
                    .font(.footnote)
                    .foregroundStyle(result.hasPrefix("Passed") ? .green : (result.hasPrefix("Failed") ? .red : .primary))
            }
            Text("Tests whether WiiPad can generate and run machine code (needed for the recompiler). Results are written to WiiPad.log (lines starting with \"jit:\"). Run it before loading a title.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active { model.refresh() }
        }
    }
}
