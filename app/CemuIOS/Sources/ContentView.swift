import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(spacing: 16) {
            Text("Cemu iPadOS")
                .font(.largeTitle.bold())
            Text("Build system online.")
                .font(.title3)
                .foregroundStyle(.secondary)
            // Comes from Objective-C++ (BuildInfo.mm). Proves the Swift → Objective-C++ → C++
            // path works before the real CemuBridge and Cemu core are added.
            Text(BuildInfo.summary())
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 24)
        }
        .padding()
    }
}
