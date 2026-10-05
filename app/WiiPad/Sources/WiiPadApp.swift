import SwiftUI

@main
struct WiiPadApp: App {
    init() {
        // First access opens Documents/WiiPad.log and logs device, OS and memory info.
        CemuBridge.shared.log("app startup")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
