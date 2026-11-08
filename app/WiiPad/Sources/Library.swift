import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// One game in the library: a bookmark to the user's own dump (folder or .wua/.wud/.wux/.wuhb/.rpx file) plus what
/// was read from it (name, title ID, the game's icon). Icons are cached as PNG in Application Support.
struct LibraryEntry: Codable, Identifiable, Equatable {
    var id: UUID
    var bookmark: Data
    var name: String
    var titleId: String?
    var fileName: String
    var hasIcon: Bool
    var added: Date
    var lastPlayed: Date?
}

@MainActor
final class LibraryStore: ObservableObject {
    static let shared = LibraryStore()

    @Published private(set) var entries: [LibraryEntry] = []
    @Published private(set) var importing = 0
    @Published var message: String?

    private var coreReady = false
    private var pending: [URL] = []
    private var icons: [UUID: UIImage] = [:]

    private let folder: URL
    private var listFile: URL { folder.appendingPathComponent("library.json") }

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        folder = support.appendingPathComponent("WiiPadLibrary", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: listFile),
           let list = try? JSONDecoder().decode([LibraryEntry].self, from: data) {
            entries = list
        }
    }

    /// Recently played first, then by name.
    var sorted: [LibraryEntry] {
        entries.sorted { a, b in
            switch (a.lastPlayed, b.lastPlayed) {
            case let (x?, y?): return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        }
    }

    func icon(for entry: LibraryEntry) -> UIImage? {
        guard entry.hasIcon else { return nil }
        if let cached = icons[entry.id] { return cached }
        let image = UIImage(contentsOfFile: iconFile(entry.id).path)
        icons[entry.id] = image
        return image
    }

    /// Called once the Cemu core is initialized (title inspection mounts the title through Cemu's filesystem).
    /// `savedTitle`: the title from earlier builds (single "Reopen" bookmark), imported into an empty library.
    func coreBecameReady(savedTitle: URL?) {
        guard !coreReady else { return }
        coreReady = true
        if entries.isEmpty, let savedTitle {
            CemuBridge.shared.log("library: importing the previously opened title")
            pending.insert(savedTitle, at: 0)
        }
        let queued = pending
        pending.removeAll()
        queued.forEach(add)
    }

    /// Adds a title chosen in the Files picker (security-scoped URL).
    func add(_ url: URL) {
        guard coreReady else { pending.append(url); return }
        let accessing = url.startAccessingSecurityScopedResource()
        let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        if accessing { url.stopAccessingSecurityScopedResource() }
        guard let bookmark else {
            message = "Couldn't keep access to \(url.lastPathComponent). Move it to On My iPhone › WiiPad and try again."
            return
        }
        importing += 1
        Task.detached(priority: .userInitiated) {
            let info = CemuBridge.shared.inspectTitle(at: url)
            await self.finishImport(url: url, bookmark: bookmark, info: info)
        }
    }

    private func finishImport(url: URL, bookmark: Data, info: [String: Any]?) {
        importing -= 1
        guard let info else {
            message = "\(url.lastPathComponent) isn't a Wii U game WiiPad can read. Choose the game's folder (with code, content and meta) or a .wua / .wud / .wux file."
            return
        }
        let titleId = info["titleId"] as? String
        var entry = LibraryEntry(id: UUID(), bookmark: bookmark,
                                 name: (info["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? url.deletingPathExtension().lastPathComponent,
                                 titleId: titleId, fileName: url.lastPathComponent, hasIcon: false, added: Date(), lastPlayed: nil)
        // the same game again (e.g. moved files): keep its play history, refresh the bookmark
        if let titleId, let index = entries.firstIndex(where: { $0.titleId == titleId }) {
            entry.id = entries[index].id
            entry.added = entries[index].added
            entry.lastPlayed = entries[index].lastPlayed
            entries.remove(at: index)
        }
        if let png = info["icon"] as? Data, (try? png.write(to: iconFile(entry.id), options: .atomic)) != nil {
            entry.hasIcon = true
            icons[entry.id] = UIImage(data: png)
        }
        entries.append(entry)
        save()
        Haptics.select()
    }

    func remove(_ entry: LibraryEntry) {
        entries.removeAll { $0.id == entry.id }
        icons[entry.id] = nil
        try? FileManager.default.removeItem(at: iconFile(entry.id))
        save()
        CemuBridge.shared.log("library: removed \(entry.name)")
    }

    /// The entry's file URL (refreshes a stale bookmark). nil if the dump moved or was deleted.
    func resolve(_ entry: LibraryEntry) -> URL? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: entry.bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else {
            return nil
        }
        if stale, let index = entries.firstIndex(where: { $0.id == entry.id }) {
            let accessing = url.startAccessingSecurityScopedResource()
            if let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                entries[index].bookmark = fresh
                save()
            }
            if accessing { url.stopAccessingSecurityScopedResource() }
        }
        return url
    }

    func markPlayed(_ entry: LibraryEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index].lastPlayed = Date()
        save()
    }

    private func iconFile(_ id: UUID) -> URL {
        folder.appendingPathComponent("\(id.uuidString).png")
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: listFile, options: .atomic)
        }
    }
}

// MARK: - Home screen

enum ImportKind { case folder, file }

struct HomeView: View {
    @ObservedObject var model: BootModel
    @ObservedObject private var library = LibraryStore.shared
    @ObservedObject private var jit = JITModel.shared
    let onImport: (ImportKind) -> Void
    let onPlay: (LibraryEntry) -> Void
    let onSettings: () -> Void

    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                statusRow
                if let error = model.titleError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(Theme.rounded(14, .medium))
                        .foregroundStyle(Theme.warn)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .card(radius: 16)
                }
                librarySection
                Text("WiiPad plays Wii U games you own and dumped yourself. It includes no games, firmware or keys.")
                    .font(Theme.rounded(12))
                    .foregroundStyle(Theme.secondaryText.opacity(0.8))
                    .padding(.top, 8)
            }
            .padding(.horizontal, sizeClass == .compact ? 18 : 36)
            .padding(.vertical, 24)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .alert("Library", isPresented: Binding(get: { library.message != nil }, set: { if !$0 { library.message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(library.message ?? "")
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("WiiPad")
                    .font(Theme.rounded(36, .heavy))
                    .foregroundStyle(Theme.accentGradient)
                Text("Wii U on iPhone Duo and iPad")
                    .font(Theme.rounded(15, .medium))
                    .foregroundStyle(Theme.secondaryText)
            }
            Spacer()
            Button(action: onSettings) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color.white.opacity(0.10)))
                    .overlay(Circle().stroke(Color.white.opacity(0.14), lineWidth: 1))
            }
            .accessibilityLabel("Settings")
        }
    }

    private var statusRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                engineStatus
                if jit.ready {
                    StatusPill(systemImage: "bolt.fill", text: "JIT ready")
                } else {
                    Button { jit.start() } label: {
                        StatusPill(systemImage: jit.busy ? "hourglass" : "bolt.slash.fill",
                                   text: jit.busy ? "Waiting for StikDebug…" : "JIT off · Tap to enable", tint: Theme.warn)
                    }
                    .disabled(jit.busy)
                }
                if library.importing > 0 {
                    StatusPill(systemImage: "arrow.down.circle", text: "Adding game…", tint: Theme.accent)
                }
            }
        }
    }

    @ViewBuilder
    private var engineStatus: some View {
        if model.coreFailed {
            StatusPill(systemImage: "xmark.octagon.fill", text: "Engine failed · see Settings › Diagnostics", tint: Theme.hot)
        } else if model.readyForTitle {
            StatusPill(systemImage: "checkmark.circle.fill", text: "Engine ready")
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(Theme.accent)
                Text("Starting engine…")
            }
            .font(Theme.rounded(13, .semibold))
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(Theme.accent.opacity(0.14)))
        }
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: sizeClass == .compact ? 138 : 168, maximum: 220), spacing: 16)]
    }

    @ViewBuilder
    private var librarySection: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Library")
                .font(Theme.rounded(24, .bold))
            if !library.entries.isEmpty {
                Text("\(library.entries.count)")
                    .font(Theme.rounded(15, .semibold))
                    .foregroundStyle(Theme.secondaryText)
            }
            Spacer()
            addMenu {
                Label("Add", systemImage: "plus")
                    .font(Theme.rounded(15, .semibold))
            }
            .buttonStyle(GlassButtonStyle())
        }

        if library.entries.isEmpty {
            emptyLibrary
        } else {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                ForEach(library.sorted) { entry in
                    GameCard(entry: entry, icon: library.icon(for: entry), enabled: canPlay) {
                        onPlay(entry)
                    }
                    .contextMenu {
                        Button { onPlay(entry) } label: { Label("Play", systemImage: "play.fill") }
                            .disabled(!canPlay)
                        Button(role: .destructive) { library.remove(entry) } label: {
                            Label("Remove from Library", systemImage: "trash")
                        }
                    }
                }
            }
        }
    }

    private var canPlay: Bool { model.readyForTitle && !model.loadingTitle && !model.titleLaunched }

    private func addMenu<Label: View>(@ViewBuilder label: () -> Label) -> some View {
        Menu {
            Button { onImport(.folder) } label: { SwiftUI.Label("Game folder…", systemImage: "folder") }
            Button { onImport(.file) } label: { SwiftUI.Label("Game file (.wua, .wud, .wux)…", systemImage: "doc") }
        } label: {
            label()
        }
    }

    private var emptyLibrary: some View {
        VStack(spacing: 14) {
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(Theme.accentGradient)
            Text("Add your first game")
                .font(Theme.rounded(20, .bold))
            Text("Choose a dumped game's folder (with code, content and meta) or a .wua, .wud or .wux file from the Files app. Store games On My iPhone for the fastest loading.")
                .font(Theme.rounded(14))
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            addMenu {
                Label("Add a Game", systemImage: "plus")
            }
            .buttonStyle(AccentButtonStyle())
            .padding(.top, 4)
        }
        .padding(28)
        .frame(maxWidth: .infinity)
        .card()
    }
}

/// Library tile: the game's icon, name and when it was last played.
struct GameCard: View {
    let entry: LibraryEntry
    let icon: UIImage?
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                artwork
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 1))
                    .shadow(color: .black.opacity(0.45), radius: 14, y: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .font(Theme.rounded(15, .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(subtitle)
                        .font(Theme.rounded(12, .medium))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(CardPressStyle())
        .opacity(enabled ? 1 : 0.55)
        .disabled(!enabled)
    }

    @ViewBuilder
    private var artwork: some View {
        if let icon {
            Image(uiImage: icon)
                .resizable()
                .interpolation(.high)
                .scaledToFill()
        } else {
            ZStack {
                Theme.accentGradient.opacity(0.35)
                Text(initials)
                    .font(Theme.rounded(40, .heavy))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
    }

    private var initials: String {
        let words = entry.name.split(separator: " ").prefix(2)
        return words.compactMap { $0.first.map(String.init) }.joined().uppercased()
    }

    private var subtitle: String {
        if let played = entry.lastPlayed {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            return "Played \(formatter.localizedString(for: played, relativeTo: Date()))"
        }
        return "Not played yet"
    }
}

struct CardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Full-screen card shown while a game is being prepared (until Cemu's own boot screen takes over).
struct LaunchView: View {
    let name: String
    let icon: UIImage?
    @State private var pulse = false

    var body: some View {
        ZStack {
            AppBackground()
            VStack(spacing: 22) {
                Group {
                    if let icon {
                        Image(uiImage: icon).resizable().interpolation(.high).scaledToFill()
                    } else {
                        ZStack {
                            Theme.accentGradient.opacity(0.4)
                            Image(systemName: "gamecontroller.fill")
                                .font(.system(size: 48, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                }
                .frame(width: 150, height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
                .shadow(color: Theme.accent.opacity(pulse ? 0.55 : 0.2), radius: pulse ? 36 : 18)
                .scaleEffect(pulse ? 1.0 : 0.97)
                .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: pulse)

                Text(name)
                    .font(Theme.rounded(24, .bold))
                    .multilineTextAlignment(.center)
                HStack(spacing: 10) {
                    ProgressView().tint(Theme.accent)
                    Text("Starting…")
                        .font(Theme.rounded(15, .medium))
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            .padding(32)
        }
        .onAppear { pulse = true }
    }
}
