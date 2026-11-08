import SwiftUI

@main
struct WiiPadApp: App {
    init() {
        // First access opens Documents/WiiPad.log and logs device, OS and memory info.
        CemuBridge.shared.log("app startup")
        // Bluetooth controllers can connect before a game starts
        Task { @MainActor in ControllerManager.shared.start() }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
