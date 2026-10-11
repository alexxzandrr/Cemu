import SwiftUI
import UIKit

/// Phase 3: asks StikDebug to attach to WiiPad (stikdebug://enable-jit with its universal.js script, the iOS 26+ TXM
/// path), waits until the debugger is attached, then has CemuBridge prepare the JIT code arena (which detaches
/// StikDebug again). Titles launched afterwards run on Cemu's recompiler.
@MainActor
final class JITModel: ObservableObject {
    @Published var status = CemuBridge.shared.jitStatus
    @Published var ready = CemuBridge.shared.jitReady
    @Published var result: String?
    @Published var busy = false

    private var waitTask: Task<Void, Never>?

    func refresh() {
        status = CemuBridge.shared.jitStatus
        ready = CemuBridge.shared.jitReady
    }

    func start() {
        guard !busy, !ready else { return }
        result = nil
        if CemuBridge.shared.jitDebuggerAttached {
            enable()
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
                    self.enable()
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

    private func enable() {
        guard !busy else { return }
        busy = true
        result = "Preparing JIT memory (a few seconds)…"
        Task.detached(priority: .userInitiated) {
            let line = CemuBridge.shared.enableJIT()
            await MainActor.run {
                self.result = line
                self.busy = false
                self.refresh()
            }
        }
    }
}

struct JITSection: View {
    @StateObject private var model = JITModel()
    @State private var useJIT = CemuBridge.shared.useJIT
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("JIT (recompiler)")
                .font(.headline)
            Text(model.status)
                .font(.footnote.monospaced())
                .foregroundStyle(model.ready ? .green : .secondary)
            if !model.ready {
                Button(model.busy ? "Working…" : "Enable JIT with StikDebug") {
                    model.start()
                }
                .buttonStyle(.bordered)
                .disabled(model.busy)
            }
            if let result = model.result {
                Text(result)
                    .font(.footnote)
                    .foregroundStyle(result.hasPrefix("JIT enabled") ? .green : (result.hasPrefix("Failed") ? .red : .primary))
            }
            Toggle("Use the recompiler when JIT is enabled (off: interpreter, for comparison)", isOn: $useJIT)
                .font(.footnote)
                .onChange(of: useJIT) { enabled in
                    CemuBridge.shared.useJIT = enabled
                }
            Text("Enable JIT once per app session, before loading a title: StikDebug attaches, WiiPad prepares its code memory, and StikDebug detaches again. Without JIT, titles run on the interpreter. Details in WiiPad.log (lines starting with \"jit:\").")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active { model.refresh() }
        }
    }
}
