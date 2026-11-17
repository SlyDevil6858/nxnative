// Launcher: the settings screen shown before the game starts (front_ios.m dm_show_launcher). Its settings come from the app's dm/launcher.json, which build_ipa.sh writes for this game
// from dm/games/settings.tsv (dm/games/settings.py): each sets an environment variable the host reads when the game starts. A variable an env file set (Documents/env.txt, the bundle's
// dm/env.txt; main.m lists them in DM_ENV_FILE_KEYS) is shown but kept. All settings share one screen, grouped by section (rows: LauncherRow.swift). Choices that differ from the game's default are kept
// in UserDefaults; Reset to tested defaults shows the defaults, and Play then forgets them. DM_LAUNCHER=0 in Documents/env.txt starts the game at once with the saved choices; DM_SAVED_CHOICES=0 ignores them (and keeps them)
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import os

private func info(_ key: String) -> Any? { Bundle.main.object(forInfoDictionaryKey: key) }

/// A lightweight dominant-colour estimate for tinting the launcher from the game's app icon.
private extension UIImage {
    func dominantColor() -> UIColor? {
        guard let cgImage else { return nil }
        let width = 32, height = 32
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .low
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return nil }

        struct Bucket {
            var count = 0
            var red = 0
            var green = 0
            var blue = 0
        }
        var buckets: [Int: Bucket] = [:]
        for offset in stride(from: 0, to: pixels.count, by: bytesPerPixel) {
            let alpha = Int(pixels[offset + 3])
            guard alpha > 64 else { continue }
            let red = Int(pixels[offset]), green = Int(pixels[offset + 1]), blue = Int(pixels[offset + 2])
            let brightness = (red * 299 + green * 587 + blue * 114) / 1000
            let maximum = max(red, green, blue), minimum = min(red, green, blue)
            guard brightness > 18, brightness < 248, maximum - minimum > 18 else { continue }
            let key = ((red >> 3) << 10) | ((green >> 3) << 5) | (blue >> 3)
            var bucket = buckets[key, default: Bucket()]
            bucket.count += 1
            bucket.red += red; bucket.green += green; bucket.blue += blue
            buckets[key] = bucket
        }
        guard let dominant = buckets.values.max(by: { $0.count < $1.count }), dominant.count > 0 else {
            return UIColor(red: 0.25, green: 0.48, blue: 0.85, alpha: 1)
        }
        return UIColor(red: CGFloat(dominant.red) / CGFloat(dominant.count * 255),
                       green: CGFloat(dominant.green) / CGFloat(dominant.count * 255),
                       blue: CGFloat(dominant.blue) / CGFloat(dominant.count * 255), alpha: 1)
    }
}


/// Resolve the app icon the same way the launcher header does, including its Info.plist fallback.
private func launcherAppIcon() -> UIImage? {
    if let icon = UIImage(named: "AppIcon") { return icon }
    guard let icons = info("CFBundleIcons") as? [String: Any],
          let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
          let files = primary["CFBundleIconFiles"] as? [String],
          let last = files.last else { return nil }
    return UIImage(named: last)
}

/// The original dominant app-icon colour, shared by both folder-import buttons.
private func launcherAccentColor() -> Color {
    Color(uiColor: launcherAppIcon()?.dominantColor() ?? .systemBlue)
}


/// Cloud saves: an iCloud Drive folder shared with the Mac app (chosen in its settings window's
/// Cloud saves too). The host brings the save in from there when the game starts and
/// sends it there after each save (dm/host/save_sync.h); the folder is a bookmark (CloudSaves.m).
private struct CloudSavesSection: View {
    @State private var folder: String = ""
    @State private var note: String = ""
    @State private var picking = false

    var body: some View {
        Section {
            HStack {
                Text("Cloud saves")
                Spacer()
                Text(folder.isEmpty ? "Off" : (folder as NSString).lastPathComponent)
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Button {
                picking = true
            } label: {
                Text(folder.isEmpty ? "Choose a folder in iCloud Drive…" : "Choose a different folder…")
                    .foregroundColor(launcherAccentColor())
            }
            .buttonStyle(.plain)
            if !folder.isEmpty {
                Button("Turn off cloud saves", role: .destructive) {
                    dm_clear_cloud_saves(); refresh(); note = ""
                }
            }
        } footer: {
            Text(note.isEmpty
                 ? "Choose a folder in iCloud Drive, and the same one in the Mac app's Cloud saves. The save comes in when the game starts and goes out after each save; a save that is replaced is kept in save-backups."
                 : note)
                .foregroundStyle(Color(white: 0.58))
        }
        .sheet(isPresented: $picking) {
            DocumentPicker(types: [.folder]) { url in
                picking = false
                if dm_store_cloud_saves(url) {
                    note = "Saved. The game uses this folder when you press Play."
                    refresh()
                } else {
                    note = "That folder could not be remembered — try a different one."
                }
            } onCancel: { picking = false }
        }
        .onAppear(perform: refresh)
    }

    private func refresh() {
        var stale: ObjCBool = false
        folder = dm_cloud_saves_path(&stale) ?? ""
        if stale.boolValue && folder.isEmpty {
            note = "The folder you chose before is no longer readable (the app was signed differently). Please choose it again."
        }
    }
}

/// UIDocumentPickerViewController for a folder, in the two callbacks a SwiftUI sheet wants.
private struct DocumentPicker: UIViewControllerRepresentable {
    var types: [UTType] = [.folder]
    let onPick: (URL) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // .open (not .import): the folder stays where it is and the bookmark keeps pointing at it.
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: false)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick, onCancel: onCancel) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        let onCancel: () -> Void
        init(onPick: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick; self.onCancel = onCancel
        }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { onPick(url) } else { onCancel() }
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { onCancel() }
    }
}


/// Lets the user install or remove a folder-based touch-control skin before launching the game.
private struct LauncherTheme: Identifiable {
    let name: String
    let path: String
    var id: String { path }
}

private struct LauncherView: View {
    @ObservedObject var m: LauncherModel
    let play: () -> Void
    @State private var memory = os_proc_available_memory()
    @State private var isControlLayoutEditing = false
    @State private var themes: [LauncherTheme] = []
    @State private var selectedTheme = UserDefaults.standard.string(forKey: "DmTouchControlThemeName") ?? "ANIMAL WELL"
    @State private var pickingTheme = false
    @State private var showingThemeMenu = false
    @State private var confirmingThemeDeletion = false
    @State private var themeToDelete: LauncherTheme?
    @State private var showingThemeImportAlert = false
    @State private var themeImportMessage = ""

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                VStack(spacing: 16) {
                    if let icon = appIcon() {
                        Image(uiImage: icon).resizable().frame(width: 96, height: 96)
                            .clipShape(RoundedRectangle(cornerRadius: 22))
                            .accessibilityHidden(true)
                    }
                    Text((info("CFBundleDisplayName") as? String) ?? "Game")
                        .font(.title.weight(.bold)).multilineTextAlignment(.center)
                    Text("Version \((info("CFBundleShortVersionString") as? String) ?? "") · Build \((info("CFBundleVersion") as? String) ?? "1")")
                        .font(.callout).foregroundStyle(.secondary)
                    playButton
                }
                .padding(16)
                .frame(width: geometry.size.width * 0.30, height: geometry.size.height)
                List {
                    ForEach(m.sections, id: \.self) { section in
                        let rows = m.rows(in: section)
                        if !rows.isEmpty {
                            Section(section == "Controls" ? "Touch controls" : section) {
                                ForEach(rows) { SettingRow(s: $0, m: m, accentColor: accentColor) }
                                if section == "Controls" {
                                    Button {
                                        showingThemeMenu = true
                                    } label: {
                                        HStack {
                                            Text("Touch controls theme")
                                                .foregroundStyle(.white)
                                            Spacer()
                                            Text(selectedTheme)
                                                .foregroundStyle(accentColor)
                                            Image(systemName: "chevron.down")
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(accentColor)
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .popover(isPresented: $showingThemeMenu, arrowEdge: .trailing) {
                                        VStack(alignment: .leading, spacing: 0) {
                                            ForEach(themes) { theme in
                                                Divider()
                                                HStack(spacing: 12) {
                                                    Button {
                                                        selectTheme(theme.path, name: theme.name)
                                                        showingThemeMenu = false
                                                    } label: {
                                                        HStack {
                                                            Text(theme.name)
                                                            Spacer()
                                                            if selectedTheme == theme.name {
                                                                Image(systemName: "checkmark")
                                                                    .foregroundStyle(accentColor)
                                                            }
                                                        }
                                                        .frame(maxWidth: .infinity, alignment: .leading)
                                                        .contentShape(Rectangle())
                                                    }
                                                    .buttonStyle(.plain)
                                                    if canDeleteTheme(theme) {
                                                        Button(role: .destructive) {
                                                            showingThemeMenu = false
                                                            themeToDelete = theme
                                                            confirmingThemeDeletion = true
                                                        } label: {
                                                            Image(systemName: "trash")
                                                                .foregroundStyle(.red)
                                                                .frame(width: 32, height: 32)
                                                                .contentShape(Rectangle())
                                                        }
                                                        .buttonStyle(.plain)
                                                        .accessibilityLabel("Delete \(theme.name)")
                                                    }
                                                }
                                                .padding(.vertical, 4)
                                            }
                                        }
                                        .padding(12)
                                        .frame(minWidth: 240)
                                        .presentationCompactAdaptation(.popover)
                                    }
                                    Button("Edit touch controls layout…") { dm_gamepad_present_launcher_editor() }
                                        .foregroundStyle(accentColor)
                                    Button("Import touch controls theme…") { pickingTheme = true }
                                        .foregroundStyle(accentColor)
                                    (Text("QUICK TIP: ")
                                        .foregroundColor(Color(red: 245 / 255, green: 176 / 255, blue: 15 / 255))
                                        .fontWeight(.bold)
                                     + Text("During gameplay, press and hold the 2D or 3D button, or hold Select on your controller, to open the in-game control menu.")
                                        .foregroundColor(Color(white: 0.58)))
                                        .font(.footnote)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    .listRowBackground(Color.black)
                                }
                            }
                        }
                    }
                    Section {
                        Button { m.reset() } label: {
                            Text("Reset to tested defaults")
                                .foregroundStyle(m.changed ? accentColor : Color(white: 0.58))
                        }
                        .buttonStyle(.plain)
                        .disabled(!m.changed)
                    } footer: {
                        Text("Brings back all settings this game was tested with.")
                            .foregroundStyle(Color(white: 0.58))
                    }
                    CloudSavesSection()
                    Section {
                        HStack {
                            Text("Memory available")
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: Int64(memory), countStyle: .memory)).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
                .listStyle(.plain)
                .listRowBackground(Color.black)
                .background(Color.black)
                .contentMargins(.horizontal, 0, for: .scrollContent)
                .frame(width: geometry.size.width * 0.70)
                .scrollContentBackground(.hidden)
                .environment(\.colorScheme, .dark)
            }
            .opacity(isControlLayoutEditing ? 0 : 1)
            .animation(.easeInOut(duration: 0.25), value: isControlLayoutEditing)
            .allowsHitTesting(!isControlLayoutEditing)
            .background {
                if let background = launcherBackground() {
                    Image(uiImage: background).resizable().scaledToFill()
                        .overlay(.black.opacity(0.48))
                        .ignoresSafeArea()
                }
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $pickingTheme) {
            DocumentPicker(types: [.folder]) { url in
                pickingTheme = false
                importTheme(from: url)
            } onCancel: { pickingTheme = false }
        }
        .alert("Touch controls theme", isPresented: $showingThemeImportAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(themeImportMessage)
        }
        .confirmationDialog("Delete imported touch control theme?", isPresented: $confirmingThemeDeletion, titleVisibility: .visible) {
            Button("Delete \(themeToDelete?.name ?? "theme")", role: .destructive) {
                if let theme = themeToDelete { deleteTheme(theme) }
                themeToDelete = nil
            }
            Button("Cancel", role: .cancel) { themeToDelete = nil }
        } message: {
            Text("This permanently deletes the imported theme folder from this device.")
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("DmPadLauncherEditorVisibilityChanged"))) { notification in
            isControlLayoutEditing = (notification.userInfo?["editing"] as? Bool) ?? false
        }
        .onAppear(perform: refreshThemes)
        .task {
            while !Task.isCancelled {
                memory = os_proc_available_memory()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private var accentTextColor: Color {
        let ui = UIColor(accentColor)
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 1
        if ui.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
            let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
            return luminance > 0.58 ? .black : .white
        }
        return .white
    }

    @ViewBuilder var playButton: some View {
        let button = Button(action: play) {
            Text("Play").font(.title3.weight(.semibold)).frame(maxWidth: 220)
                .foregroundStyle(accentTextColor)
        }.controlSize(.large).tint(accentColor)
        if #available(iOS 26.0, *) { button.buttonStyle(.glassProminent) } else { button.buttonStyle(.borderedProminent) }
    }

    private func launcherBackground() -> UIImage? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("dm/launcher-custom-background.png") else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    private var accentColor: Color {
        Color(uiColor: appIcon()?.dominantColor() ?? .systemBlue)
    }

    private func appIcon() -> UIImage? {
        launcherAppIcon()
    }

    private func themesDirectory() -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let directory = documents.appendingPathComponent("TouchControlThemes", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Built-in themes stay read-only in the app bundle. Only imported themes live in Documents.
        // Remove the retired Well built-in left by older builds.
        for retired in ["Well"] {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(retired, isDirectory: true))
        }
        let bundledRoot = Bundle.main.resourceURL?.appendingPathComponent("TouchControlThemes", isDirectory: true)
        // FOREST is shipped in the bundle, then installed as a deletable, Files-visible copy in Documents.
        let forestSource = bundledRoot?.appendingPathComponent("FOREST", isDirectory: true)
        let forestDestination = directory.appendingPathComponent("FOREST", isDirectory: true)
        let forestDeletionMarker = directory.appendingPathComponent(".FOREST.deleted")
        if let forestSource, !FileManager.default.fileExists(atPath: forestDestination.path),
           !FileManager.default.fileExists(atPath: forestDeletionMarker.path) {
            try? FileManager.default.copyItem(at: forestSource, to: forestDestination)
        }
        // Remove identical legacy copies of the other bundled themes, but preserve editable FOREST.
        if let bundledRoot,
           let bundledFolders = try? FileManager.default.contentsOfDirectory(at: bundledRoot, includingPropertiesForKeys: [.isDirectoryKey]) {
            for bundled in bundledFolders where (try? bundled.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                if bundled.lastPathComponent.caseInsensitiveCompare("FOREST") == .orderedSame { continue }
                let legacy = directory.appendingPathComponent(bundled.lastPathComponent, isDirectory: true)
                let bundledJSON = try? Data(contentsOf: bundled.appendingPathComponent("theme.json"))
                let legacyJSON = try? Data(contentsOf: legacy.appendingPathComponent("theme.json"))
                if let bundledJSON, bundledJSON == legacyJSON {
                    try? FileManager.default.removeItem(at: legacy)
                }
            }
        }
        return directory
    }

    private func isBundledTheme(_ theme: LauncherTheme) -> Bool {
        guard let bundledRoot = Bundle.main.resourceURL?.appendingPathComponent("TouchControlThemes", isDirectory: true) else {
            return false
        }
        let path = URL(fileURLWithPath: theme.path).standardizedFileURL.path
        let root = bundledRoot.standardizedFileURL.path + "/"
        return path.hasPrefix(root)
    }

    private func canDeleteTheme(_ theme: LauncherTheme) -> Bool {
        let folderName = URL(fileURLWithPath: theme.path).lastPathComponent
        guard folderName.caseInsensitiveCompare("ANIMAL WELL") != .orderedSame,
              folderName.caseInsensitiveCompare("CLASSIC") != .orderedSame,
              theme.name.caseInsensitiveCompare("ANIMAL WELL") != .orderedSame,
              theme.name.caseInsensitiveCompare("CLASSIC") != .orderedSame else { return false }
        let documentsRoot = themesDirectory().standardizedFileURL.path + "/"
        return URL(fileURLWithPath: theme.path).standardizedFileURL.path.hasPrefix(documentsRoot)
    }

    private func deleteTheme(_ theme: LauncherTheme) {
        guard canDeleteTheme(theme) else { return }
        do {
            if URL(fileURLWithPath: theme.path).lastPathComponent.caseInsensitiveCompare("FOREST") == .orderedSame {
                let marker = themesDirectory().appendingPathComponent(".FOREST.deleted")
                FileManager.default.createFile(atPath: marker.path, contents: Data())
            }
            try FileManager.default.removeItem(at: URL(fileURLWithPath: theme.path))
            if selectedTheme == theme.name,
               let animalWell = themes.first(where: { URL(fileURLWithPath: $0.path).lastPathComponent.caseInsensitiveCompare("ANIMAL WELL") == .orderedSame }) {
                selectTheme(animalWell.path, name: animalWell.name)
            }
            refreshThemes()
        } catch {
            NSLog("Touch theme deletion failed: %@", error.localizedDescription)
        }
    }

    private func themeJSON(in folder: URL) -> [String: Any]? {
        let file = folder.appendingPathComponent("theme.json")
        guard let data = try? Data(contentsOf: file),
              let object = try? JSONSerialization.jsonObject(with: data),
              let json = object as? [String: Any],
              let palette = json["palette"] as? [String: Any] else { return nil }
        let required = ["idle", "pressed", "outline", "ringFill", "text", "pressedText"]
        for key in required {
            guard let value = palette[key] as? String else { return nil }
            let hex = value.hasPrefix("#") ? String(value.dropFirst()) : value
            guard hex.range(of: "^[0-9A-Fa-f]{6}$", options: .regularExpression) != nil else { return nil }
        }
        return json
    }

    private func refreshThemes() {
        let documentsRoot = themesDirectory()
        let bundledRoot = Bundle.main.resourceURL?.appendingPathComponent("TouchControlThemes", isDirectory: true)
        let bundledFolders = bundledRoot.flatMap { try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: [.isDirectoryKey]) } ?? []
        let importedFolders = (try? FileManager.default.contentsOfDirectory(at: documentsRoot, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        // When a bundled FOREST exists, show only its writable Documents copy.
        let forestDeletionMarker = documentsRoot.appendingPathComponent(".FOREST.deleted")
        let forestWasDeleted = FileManager.default.fileExists(atPath: forestDeletionMarker.path)
        let hasDocumentsForest = importedFolders.contains {
            $0.lastPathComponent.caseInsensitiveCompare("FOREST") == .orderedSame
        }
        let visibleBundled = bundledFolders.filter {
            !((hasDocumentsForest || forestWasDeleted) && $0.lastPathComponent.caseInsensitiveCompare("FOREST") == .orderedSame)
        }
        let folders = visibleBundled + importedFolders
        themes = folders.compactMap { folder in
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let json = themeJSON(in: folder) else { return nil }
            return LauncherTheme(name: (json["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? folder.lastPathComponent,
                                 path: folder.path)
        }.sorted { let lhs = URL(fileURLWithPath: $0.path).lastPathComponent.caseInsensitiveCompare("ANIMAL WELL") == .orderedSame; let rhs = URL(fileURLWithPath: $1.path).lastPathComponent.caseInsensitiveCompare("ANIMAL WELL") == .orderedSame; if lhs != rhs { return lhs }; return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let defaults = UserDefaults.standard
        let path = defaults.string(forKey: "DmTouchControlThemePath")
        if let selected = themes.first(where: { $0.path == path }) {
            selectedTheme = selected.name
        } else if let animalWell = themes.first(where: {
            URL(fileURLWithPath: $0.path).lastPathComponent.caseInsensitiveCompare("ANIMAL WELL") == .orderedSame
        }) {
            defaults.set(animalWell.path, forKey: "DmTouchControlThemePath")
            defaults.set(animalWell.name, forKey: "DmTouchControlThemeName")
            selectedTheme = animalWell.name
        } else {
            selectedTheme = "ANIMAL WELL"
            defaults.set("ANIMAL WELL", forKey: "DmTouchControlThemeName")
        }
    }

    private func selectTheme(_ path: String?, name: String) {
        if let path { UserDefaults.standard.set(path, forKey: "DmTouchControlThemePath") }
        else { UserDefaults.standard.removeObject(forKey: "DmTouchControlThemePath") }
        UserDefaults.standard.set(true, forKey: "DmTouchControlThemeExplicitlySelected")
        UserDefaults.standard.set(name, forKey: "DmTouchControlThemeName")
        selectedTheme = name
    }

    private func importTheme(from source: URL) {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        var importedName: String?
        var importFailure: String?
        var coordinationError: NSError?
        let coordinator = NSFileCoordinator(filePresenter: nil)

        coordinator.coordinate(readingItemAt: source, options: [], error: &coordinationError) { readableSource in
            let fileManager = FileManager.default
            var candidate: URL?

            if readableSource.lastPathComponent == "theme.json" {
                candidate = readableSource.deletingLastPathComponent()
            } else if themeJSON(in: readableSource) != nil {
                candidate = readableSource
            } else if let enumerator = fileManager.enumerator(
                at: readableSource,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) {
                var validFolders: [URL] = []
                for case let entry as URL in enumerator where entry.lastPathComponent == "theme.json" {
                    let folder = entry.deletingLastPathComponent()
                    if themeJSON(in: folder) != nil &&
                        !validFolders.contains(where: { $0.standardizedFileURL == folder.standardizedFileURL }) {
                        validFolders.append(folder)
                    }
                }
                if validFolders.count == 1 {
                    candidate = validFolders[0]
                } else if validFolders.isEmpty {
                    importFailure = "No valid theme.json was found. Select a theme folder containing a valid theme.json file."
                } else {
                    importFailure = "More than one valid theme was found. Select the folder for a single theme and try again."
                }
            }

            guard let candidate, let json = themeJSON(in: candidate) else {
                if importFailure == nil {
                    importFailure = "This folder does not contain a valid touch controls theme."
                }
                return
            }

            let rawName = (json["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? candidate.lastPathComponent
            let safeName = String(rawName.map {
                $0.isLetter || $0.isNumber || $0 == " " || $0 == "_" || $0 == "-" ? $0 : "_"
            }).trimmingCharacters(in: CharacterSet(charactersIn: " ._"))
            let root = themesDirectory()
            let destination = root.appendingPathComponent(safeName.isEmpty ? "Imported Theme" : safeName, isDirectory: true)
            let staging = root.appendingPathComponent(".import-\(UUID().uuidString)", isDirectory: true)

            do {
                try fileManager.copyItem(at: candidate, to: staging)
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.moveItem(at: staging, to: destination)
                importedName = rawName
            } catch {
                try? fileManager.removeItem(at: staging)
                importFailure = "The theme could not be copied into the app. \(error.localizedDescription)"
            }
        }

        if let coordinationError {
            importFailure = "The selected folder could not be accessed. \(coordinationError.localizedDescription)"
        }

        if let importedName {
            refreshThemes()
            let safeName = String(importedName.map {
                $0.isLetter || $0.isNumber || $0 == " " || $0 == "_" || $0 == "-" ? $0 : "_"
            }).trimmingCharacters(in: CharacterSet(charactersIn: " ._"))
            let destination = themesDirectory().appendingPathComponent(safeName.isEmpty ? "Imported Theme" : safeName, isDirectory: true)
            selectTheme(destination.path, name: importedName)
            themeImportMessage = "\(importedName) was imported successfully and added to the theme list."
        } else {
            themeImportMessage = importFailure ?? "The theme could not be imported for an unknown reason."
        }
        showingThemeImportAlert = true
    }
}

// Shows the launcher over the root view controller and calls done once the settings are in the environment; false (done is not called) when there is no launcher
@_cdecl("dm_show_launcher")
public func dmShowLauncher(_ viewController: UnsafeMutableRawPointer, _ done: @convention(c) () -> Void) -> Bool {
    guard let url = Bundle.main.resourceURL?.appendingPathComponent("dm/launcher.json"), let data = try? Data(contentsOf: url) else { return false }
    guard let file = try? JSONDecoder().decode(SettingsFile.self, from: data), !file.settings.isEmpty else { fputs("[RED] launcher: dm/launcher.json cannot be read; starting the game\n", stderr); return false }
    if ProcessInfo.processInfo.environment["DM_LAUNCHER"] == "0" { fputs("launcher: off (DM_LAUNCHER=0)\n", stderr); LauncherModel(file.settings).applySaved(); return false }
    let parent = Unmanaged<UIViewController>.fromOpaque(viewController).takeUnretainedValue()
    let model = LauncherModel(file.settings)
    var host: UIViewController?
    let view = LauncherView(m: model) {
        guard let h = host else { return }
        host = nil
        model.apply()
        h.dismiss(animated: false) { done() }
    }
    let h = UIHostingController(rootView: view)
    h.modalPresentationStyle = .fullScreen
    h.overrideUserInterfaceStyle = .dark
    host = h
    parent.present(h, animated: false)
    fputs("launcher: \(file.settings.count) settings shown\n", stderr)
    return true
}
