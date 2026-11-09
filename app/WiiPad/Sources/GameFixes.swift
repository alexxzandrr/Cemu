import SwiftUI

/// Per-game graphics options, written as a Cemu game profile (Documents/gameProfiles/<title ID>.ini, which Cemu reads
/// before its bundled defaults when a game starts). For rendering bugs such as stretched or exploding geometry on Apple
/// GPUs, which on Cemu's Metal backend usually come from one of these three options.
struct GameGraphicsFixes: Equatable {
    /// Cemu "shaderFastMath": faster shader math; can break some games' vertex math (default on)
    var fastMath = true
    /// Cemu "metalBufferCacheMode2": 0 auto (Apple GPU: device private), 1 device private, 2 device shared, 3 host
    var bufferCache = 0
    /// Cemu "positionInvariance2": 0 auto, 1 off, 2 on
    var positionInvariance = 0

    static func file(for titleId: String) -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("gameProfiles/\(titleId.lowercased()).ini")
    }

    static func load(titleId: String) -> GameGraphicsFixes {
        var fixes = GameGraphicsFixes()
        guard let text = try? String(contentsOf: file(for: titleId), encoding: .utf8) else { return fixes }
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "shaderfastmath": fixes.fastMath = parts[1] == "true" || parts[1] == "1"
            case "metalbuffercachemode2": fixes.bufferCache = Int(parts[1]) ?? 0
            case "positioninvariance2": fixes.positionInvariance = Int(parts[1]) ?? 0
            default: break
            }
        }
        return fixes
    }

    func save(titleId: String) {
        let url = Self.file(for: titleId)
        if self == GameGraphicsFixes() {
            try? FileManager.default.removeItem(at: url) // all defaults: no profile
            CemuBridge.shared.log("game fixes: \(titleId): back to defaults")
            return
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = """
        # Written by WiiPad (Settings > Game fixes)
        [Graphics]
        shaderFastMath = \(fastMath ? "true" : "false")
        metalBufferCacheMode2 = \(bufferCache)
        positionInvariance2 = \(positionInvariance)

        """
        try? text.write(to: url, atomically: true, encoding: .utf8)
        CemuBridge.shared.log("game fixes: \(titleId): fast math \(fastMath), buffer cache \(bufferCache), position invariance \(positionInvariance)")
    }
}

struct GameFixesView: View {
    let entry: LibraryEntry
    @State private var fixes = GameGraphicsFixes()
    @State private var loaded = false

    var body: some View {
        Form {
            Section {
                Toggle("Fast shader math", isOn: $fixes.fastMath)
                Picker("Buffer cache", selection: $fixes.bufferCache) {
                    Text("Automatic").tag(0)
                    Text("GPU copy").tag(1)
                    Text("Shared").tag(2)
                    Text("Game memory").tag(3)
                }
                Picker("Position invariance", selection: $fixes.positionInvariance) {
                    Text("Automatic").tag(0)
                    Text("Off").tag(1)
                    Text("On").tag(2)
                }
            } footer: {
                Text("For rendering bugs such as stretched or exploding geometry. Change one option at a time and restart the game (close WiiPad from the app switcher) to see its effect. Try first: Fast shader math off, then Buffer cache Shared.")
            }
            Section {
                Button("Reset to defaults", role: .destructive) { fixes = GameGraphicsFixes() }
            }
        }
        .navigationTitle(entry.name)
        .onAppear {
            guard !loaded, let id = entry.titleId else { return }
            fixes = GameGraphicsFixes.load(titleId: id)
            loaded = true
        }
        .onChange(of: fixes) { value in
            guard loaded, let id = entry.titleId else { return }
            value.save(titleId: id)
        }
    }
}
