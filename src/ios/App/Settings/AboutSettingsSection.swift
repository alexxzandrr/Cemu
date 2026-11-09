import SwiftUI

private extension Bundle {
    var appVersionString: String {
        let short = infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }
}

struct AboutSettingsSection: View {
    @State private var showingResetConfirmation = false
    @State private var resetMessage: String?

    var body: some View {
        Section {
            SettingsRow(label: "Version", value: Bundle.main.appVersionString, icon: "number")
            SettingsRow(label: "WiiPad by", value: "alexxzandrr", icon: "person.fill")
            Link(destination: URL(string: "https://github.com/alexxzandrr/Cemu/tree/duo")!) {
                Label("WiiPad source code (GitHub)", systemImage: "arrow.up.right.square")
                    .font(.subheadline.weight(.semibold))
            }
            NavigationLink {
                OpenSourceLicencesView()
            } label: {
                Label("Open-source licences", systemImage: "doc.text")
                    .font(.subheadline.weight(.semibold))
            }

            // Credits required by the EspressU Licence and the Crema Licence (LICENSES/EspressU-Licence.txt,
            // src/ios/App/Crema/LICENSE.txt): shown next to the link to WiiPad's public source repository.
            VStack(alignment: .leading, spacing: 4) {
                Text("This product includes work by EspressU (https://espressu.dev).")
                Text("EspressU (https://espressu.dev)")
                Text("Crema touch controls by EspressU (https://espressu.dev)")
                Text("WiiPad is an unofficial, non-commercial fork for iPhone Duo. It is built on Cemu and EspressU, which is based on [MuffinEMU](https://github.com/MuffinEMU/Muffin-EMU) by Void. EspressU does not endorse WiiPad. Wii U is a trademark of Nintendo; WiiPad is not affiliated with Nintendo.")
            }
            .font(.system(size: 12))
            .foregroundColor(EspressUTheme.secondaryText)

            SettingsOnboardingRow(onRequestReopen: {
                NotificationCenter.default.post(name: .espressuReopenOnboarding, object: nil)
            })

            Button(role: .destructive) {
                showingResetConfirmation = true
            } label: {
                DestructiveSettingsLabel(title: "Reset settings to defaults", systemImage: "arrow.counterclockwise")
            }

            if let resetMessage {
                Text(resetMessage)
                    .font(.system(size: 12))
                    .foregroundColor(EspressUTheme.secondaryText)
            }
        } header: {
            SettingsSectionHeader("About", icon: "info.circle", accent: .system)
        }
        .foregroundColor(EspressUTheme.brownDarkest)
        .confirmationDialog("Reset settings to defaults?", isPresented: $showingResetConfirmation, titleVisibility: .visible) {
            Button("Reset Settings", role: .destructive) {
                SettingsDefaults.reset(includingPerGameOverrides: false)
                resetMessage = "Settings reset to defaults."
                NotificationCenter.default.post(name: .espressuReopenOnboarding, object: nil)
            }
            Button("Reset Settings and Per-Game Options", role: .destructive) {
                SettingsDefaults.reset(includingPerGameOverrides: true)
                resetMessage = "Settings and per-game options reset to defaults."
                NotificationCenter.default.post(name: .espressuReopenOnboarding, object: nil)
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Puts every option in Settings back to its default, including controls, graphics, audio, overlay, appearance and Built-in JIT with its pairing file, and shows the welcome guide again. Your library, favourites, keys.txt, accounts and theme are not affected. Per-game options stay unless you pick the second button.")
        }
    }
}
