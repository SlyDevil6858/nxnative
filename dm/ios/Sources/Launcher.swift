// Launcher: the settings screen shown before the game starts (front_ios.m dm_show_launcher). Its settings come from the app's dm/launcher.json, which build_ipa.sh writes for this game
// from dm/games/settings.tsv (dm/games/settings.py): each sets an environment variable the host reads when the game starts. A variable an env file set (Documents/env.txt, the bundle's
// dm/env.txt; main.m lists them in DM_ENV_FILE_KEYS) is shown but kept. All settings share one screen, grouped by section (rows: LauncherRow.swift). Choices that differ from the game's default are kept
// in UserDefaults; Reset to tested defaults shows the defaults, and Play then forgets them. DM_LAUNCHER=0 in Documents/env.txt starts the game at once with the saved choices; DM_SAVED_CHOICES=0 ignores them (and keeps them)
import SwiftUI
import UIKit
import ImageIO
import UniformTypeIdentifiers
import os

private func info(_ key: String) -> Any? { Bundle.main.object(forInfoDictionaryKey: key) }

/// Decode bundled launcher artwork at the size it will actually be displayed.
/// ImageIO downsamples large source images before creating a UIImage, avoiding
/// a full-resolution decode and keeping launcher memory use predictable.
private func loadLauncherImage(at url: URL, maxPixelSize: CGFloat) -> UIImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: max(1, Int(maxPixelSize)),
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
    return UIImage(cgImage: image)
}

/// Optional support webpage configured by the build workflow.
private func launcherSupportURL() -> URL? {
    guard let raw = info("DMSupportURL") as? String else { return nil }
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: value),
          let scheme = url.scheme?.lowercased(),
          scheme == "https" || scheme == "http",
          url.host != nil else { return nil }
    return url
}

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
    // Sample the exact source image used to generate this build's app icon.
    // App-icon catalog images are not reliably available through UIImage(named:).
    if let iconURL = Bundle.main.url(forResource: "launcher-custom-icon", withExtension: "png", subdirectory: "dm"),
       let icon = UIImage(contentsOfFile: iconURL.path) {
        return icon
    }
    if let icon = UIImage(named: "AppIcon") { return icon }
    guard let icons = info("CFBundleIcons") as? [String: Any],
          let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
          let files = primary["CFBundleIconFiles"] as? [String],
          let last = files.last else { return nil }
    return UIImage(named: last)
}

/// Whether this build uses the game's app-icon colour for launcher accents.
private func launcherUsesDominantAccent() -> Bool {
    guard let value = info("DMDominantAccent") else { return true }
    if let string = value as? String {
        return ["true", "yes", "1"].contains(string.lowercased())
    }
    if let number = value as? NSNumber { return number.boolValue }
    return true
}

/// Optional six-digit custom launcher accent supplied by the build workflow.
private func launcherCustomAccentColor() -> UIColor? {
    guard let rawHex = info("DMLauncherAccentHex") as? String else { return nil }
    let hex = rawHex.trimmingCharacters(in: .whitespacesAndNewlines)
        .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }

    return UIColor(
        red: CGFloat((value >> 16) & 0xFF) / 255.0,
        green: CGFloat((value >> 8) & 0xFF) / 255.0,
        blue: CGFloat(value & 0xFF) / 255.0,
        alpha: 1.0
    )
}

/// Shared launcher accent. When dominant styling is off, a supplied custom
/// colour wins; an empty custom value preserves nxnative's standard system blue.
private func launcherAccentColor() -> Color {
    guard launcherUsesDominantAccent() else {
        return Color(uiColor: launcherCustomAccentColor() ?? .systemBlue)
    }
    return Color(uiColor: launcherAppIcon()?.dominantColor() ?? .systemBlue)
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
    @State private var selectedTheme = UserDefaults.standard.string(forKey: "DmTouchControlThemeName") ?? "CLASSIC"
    @State private var pickingTheme = false
    @State private var showingThemeList = false
    @State private var confirmingThemeDeletion = false
    @State private var themeToDelete: LauncherTheme?
    @State private var themeRenamePath: String?
    @State private var themeRenameText = ""
    @FocusState private var themeRenameFocused: Bool
    @State private var showingThemeImportAlert = false
    @State private var themeImportMessage = ""

    var body: some View {
        GeometryReader { geometry in
            HStack(alignment: .top, spacing: 0) {
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
                .frame(width: geometry.size.width * 0.30, height: geometry.size.height, alignment: .center)
                // Keep the left panel anchored to its normal top position while
                // allowing it to extend behind the keyboard without resizing it.
                .ignoresSafeArea(.keyboard, edges: themeRenamePath != nil ? .bottom : [])
                .contentShape(Rectangle())
                .onTapGesture {
                    if themeRenamePath != nil { cancelLauncherThemeRename() }
                }
                // Keep the stationary game panel out of the drawer's animation
                // transaction without painting an opaque rectangle over the artwork.
                .transaction { transaction in
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                }
                ScrollViewReader { themeScrollProxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                        ForEach(m.sections, id: \.self) { section in
                            if section == "Performance", let supportURL = launcherSupportURL() {
                                Text("Support")
                                    .font(.headline)
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 16)
                                    .padding(.top, 12)
                                    .padding(.bottom, 8)
                                Button("Support the author of this port…") {
                                    UIApplication.shared.open(supportURL)
                                }
                                .foregroundStyle(Color(red: 245.0 / 255.0, green: 176.0 / 255.0, blue: 15.0 / 255.0))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                Rectangle()
                                    .fill(Color.white.opacity(0.12))
                                    .frame(height: 0.5)
                                    .padding(.horizontal, 16)
                            }
                            let rows = m.rows(in: section)
                            if !rows.isEmpty {
                                Text(section == "Controls" ? "Touch controls" : section)
                                    .font(.headline)
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 16)
                                    .padding(.top, 12)
                                    .padding(.bottom, 8)
                                ForEach(rows) {
                                    SettingRow(s: $0, m: m, accentColor: accentColor)
                                        // Toggle switches reach the panel edge; keep the label inset.
                                        .padding(.leading, 16)
                                        .padding(.trailing, $0.kind == "choice" ? 16 : 0)
                                        .padding(.vertical, 9)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .overlay(alignment: .bottom) {
                                            Rectangle().fill(Color.white.opacity(0.12)).frame(height: 0.5)
                                        }
                                }
                                if section == "Controls" {
                                    DisclosureGroup(isExpanded: $showingThemeList) {
                                        themeMenuContent
                                    } label: {
                                        HStack(spacing: 6) {
                                            Text("Touch controls theme")
                                                .foregroundStyle(.white)
                                            Spacer(minLength: 6)
                                            Text(selectedTheme)
                                                .foregroundStyle(accentColor)
                                                .lineLimit(1)
                                        }
                                        .padding(.horizontal, 16)
                                    }
                                    .disclosureGroupStyle(LauncherDisclosureGroupStyle(accentColor: accentColor))
                                    .background(Color.black)
                                    .padding(.vertical, 9)
                                    .onChange(of: showingThemeList, perform: themeListVisibilityChanged)
                                    Button("Edit touch controls layout…") {
                                        dm_gamepad_present_launcher_editor()
                                    }
                                    .foregroundStyle(accentColor)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 10)
                                    Button("Import touch controls theme…") { pickingTheme = true }
                                        .foregroundStyle(accentColor)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 10)
                                    (Text("QUICK TIP: ")
                                        .foregroundColor(Color(red: 245 / 255, green: 176 / 255, blue: 15 / 255))
                                        .fontWeight(.bold)
                                     + Text("During gameplay, press and hold the 2D, 3D, or Tap button, or hold Select on your controller, to open the in-game control menu.")
                                        .foregroundColor(Color(white: 0.58)))
                                        .font(.footnote)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 10)
                                }
                            }
                        }
                        if !m.sections.contains("Performance"), let supportURL = launcherSupportURL() {
                            Text("Support")
                                .font(.headline)
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16)
                                .padding(.top, 12)
                                .padding(.bottom, 8)
                            Button("Support the author of this port…") {
                                UIApplication.shared.open(supportURL)
                            }
                            .foregroundStyle(Color(red: 245.0 / 255.0, green: 176.0 / 255.0, blue: 15.0 / 255.0))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            Rectangle()
                                .fill(Color.white.opacity(0.12))
                                .frame(height: 0.5)
                                .padding(.horizontal, 16)
                        }
                        Button { m.reset() } label: {
                            Text("Reset to tested defaults")
                                .foregroundStyle(m.changed ? accentColor : Color(white: 0.58))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .disabled(!m.changed)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 6)
                        Text("Brings back all settings this game was tested with.")
                            .font(.footnote)
                            .foregroundStyle(Color(white: 0.58))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 12)
                        CloudSavesSection()
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                        HStack {
                            Text("Memory available")
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: Int64(memory), countStyle: .memory))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.black)
                }
                .background(Color.black)
                .frame(width: geometry.size.width * 0.70, height: geometry.size.height)
                .environment(\.colorScheme, .dark)
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: themeRenamePath) { path in
                    guard let path else { return }
                    themeRenameFocused = true
                    // Wait for the keyboard's safe-area change before scrolling,
                    // then make a second adjustment after its animation settles.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            themeScrollProxy.scrollTo("launcher-theme-\(path)", anchor: .top)
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            guard themeRenamePath == path else { return }
                            withAnimation(.easeInOut(duration: 0.2)) {
                                themeScrollProxy.scrollTo("launcher-theme-\(path)", anchor: .top)
                            }
                        }
                    }
                }
            }
            }
            .opacity(isControlLayoutEditing ? 0 : 1)
            .animation(.easeInOut(duration: 0.25), value: isControlLayoutEditing)
            .allowsHitTesting(!isControlLayoutEditing)
        }
        // Keep the artwork outside the HStack/List so drawer updates cannot move it.
        .background {
            if let background = launcherBackground() {
                Image(uiImage: background).resizable().scaledToFill()
                    .overlay(.black.opacity(0.48))
                    .ignoresSafeArea()
                    .ignoresSafeArea(.keyboard, edges: themeRenamePath != nil ? .bottom : [])
            }
        }
        // Apply keyboard avoidance to the GeometryReader and its background together.
        // This keeps the artwork anchored while the settings List handles the keyboard.
        .ignoresSafeArea(.keyboard, edges: themeRenamePath != nil ? .bottom : [])
        .preferredColorScheme(.dark)
        // Propagate the selected game-icon accent to native SwiftUI buttons and
        // controls too, not only the launcher elements that set their own tint.
        .tint(accentColor)
        // Keep the launcher underneath the pre-launch control editor fixed
        // when its theme rename field brings up the keyboard. The editor's
        // own menu handles keyboard positioning independently.
        .ignoresSafeArea(.keyboard, edges: isControlLayoutEditing ? .bottom : [])
        .sheet(isPresented: $pickingTheme) {
            DocumentPicker(types: [.folder]) { url in
                pickingTheme = false
                importTheme(from: url)
            } onCancel: { pickingTheme = false }
        }
        .alert("Touch controls theme", isPresented: $showingThemeImportAlert) {
            Button("OK", role: .cancel) { showingThemeImportAlert = false }
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
            let editing = notification.userInfo?["editing"] as? Bool ?? false
            isControlLayoutEditing = editing
            if !editing {
                refreshThemes()
            }
        }
        .onAppear(perform: refreshThemes)
        .task {
            while !Task.isCancelled {
                memory = os_proc_available_memory()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private var themeMenuContent: some View {
        VStack(spacing: 0) {
            ForEach(themes) { theme in
                HStack(spacing: 0) {
                    if themeRenamePath == theme.path {
                        TextField("Theme name", text: $themeRenameText)
                            .focused($themeRenameFocused)
                            .submitLabel(.done)
                            .textInputAutocapitalization(.words)
                            .autocorrectionDisabled()
                            .padding(.horizontal, 10)
                            .frame(height: 36)
                            .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.18), lineWidth: 1))
                            .onSubmit { saveLauncherThemeRename(theme) }
                            .padding(.leading, 8)
                        Button {
                            saveLauncherThemeRename(theme)
                        } label: {
                            Image(systemName: "checkmark")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(Color(red: 0.25, green: 0.78, blue: 0.38))
                                .frame(width: 36, height: 36)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Save theme name")
                        Button {
                            cancelLauncherThemeRename()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Color.white.opacity(0.78))
                                .frame(width: 32, height: 36)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Cancel theme rename")
                    } else {
                        Button {
                            selectTheme(theme.path, name: theme.name)
                            showingThemeList = false
                        } label: {
                            HStack(spacing: 8) {
                                Text(theme.name)
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                            }
                            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if canDeleteTheme(theme) {
                            Button {
                                themeRenameText = theme.name
                                themeRenamePath = theme.path
                            } label: {
                                Image(systemName: "pencil")
                                    .font(.system(size: 17, weight: .bold))
                                    .foregroundStyle(accentColor)
                                    .frame(width: 32, height: 32)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Rename \\(theme.name)")
                        }
                        if selectedTheme == theme.name {
                            // Put the active marker in the same trailing slot
                            // used by the custom-theme trash button.
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color(red: 0.22, green: 0.48, blue: 0.28))
                                .frame(width: 32, height: 32)
                                .accessibilityLabel("Selected theme")
                        } else if canDeleteTheme(theme) {
                            Button(role: .destructive) {
                                showingThemeList = false
                                themeToDelete = theme
                                confirmingThemeDeletion = true
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(Color(red: 0.55, green: 0.08, blue: 0.08))
                                    .frame(width: 32, height: 32)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Delete \\(theme.name)")
                        }
                    }
                }
                // Keep the row full-width even when bundled themes omit their
                // edit/delete controls, so the checkmark reaches the same
                // trailing alignment as the trash button on custom themes.
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
                .id("launcher-theme-\(theme.path)")
                Rectangle()
                    .fill(Color.white.opacity(0.12))
                    .frame(height: 0.5)
            }
        }
        .padding(.top, 4)
        // Keep the drawer's leading inset, but let its trailing edge reach the
        // settings panel boundary instead of stopping 16 points short.
        .padding(.leading, 16)
        .background(Color.black)
    }

    private func saveLauncherThemeRename(_ theme: LauncherTheme) {
        let newName = themeRenameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty,
              newName.caseInsensitiveCompare("ANIMAL WELL") != .orderedSame,
              newName.caseInsensitiveCompare("CLASSIC") != .orderedSame else { return }
        renameTheme(theme, to: newName)
        themeRenameFocused = false
        themeRenamePath = nil
    }

    private func cancelLauncherThemeRename() {
        themeRenameFocused = false
        themeRenamePath = nil
        themeRenameText = ""
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
        let screen = UIScreen.main
        let maxPixelSize = max(screen.bounds.width, screen.bounds.height) * screen.scale
        return loadLauncherImage(at: url, maxPixelSize: maxPixelSize)
    }

    private var accentColor: Color {
        launcherAccentColor()
    }

    private func appIcon() -> UIImage? {
        launcherAppIcon()
    }

    private func selectedOverrideThemeDirectory() -> URL? {
        guard let folder = info("DMOverrideFolder") as? String,
              !folder.isEmpty, folder != ".", folder != "..",
              !folder.contains("/"), !folder.contains("\\"),
              let bundleRoot = Bundle.main.resourceURL else {
            return nil
        }

        // New builds stage the selected ROM theme beside CLASSIC under the
        // shared TouchControlThemes resource folder.
        let bundledThemes = bundleRoot.appendingPathComponent("TouchControlThemes", isDirectory: true)
        let selectedTheme = bundledThemes.appendingPathComponent(folder, isDirectory: true)
        if FileManager.default.fileExists(atPath: selectedTheme.appendingPathComponent("theme.json").path) {
            return selectedTheme
        }

        // Keep compatibility with app bundles produced before ROM themes were
        // moved into TouchControlThemes.
        let legacyOverrides = bundleRoot.appendingPathComponent("OVERRIDES", isDirectory: true)
        let legacyTheme = legacyOverrides.appendingPathComponent(folder, isDirectory: true)
        return FileManager.default.fileExists(atPath: legacyTheme.appendingPathComponent("theme.json").path)
            ? legacyTheme : nil
    }

    private func bundledThemeFolders() -> [URL] {
        let bundledRoot = Bundle.main.resourceURL?.appendingPathComponent("TouchControlThemes", isDirectory: true)
        var folders = bundledRoot.flatMap {
            try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: [.isDirectoryKey])
        } ?? []
        if let selectedOverride = selectedOverrideThemeDirectory(),
           !folders.contains(where: { $0.standardizedFileURL == selectedOverride.standardizedFileURL }) {
            folders.append(selectedOverride)
        }
        return folders
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
        let bundledFolders = bundledThemeFolders()
        for bundled in bundledFolders where (try? bundled.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            if bundled.lastPathComponent.caseInsensitiveCompare("FOREST") == .orderedSame { continue }
            let legacy = directory.appendingPathComponent(bundled.lastPathComponent, isDirectory: true)
            let bundledJSON = try? Data(contentsOf: bundled.appendingPathComponent("theme.json"))
            let legacyJSON = try? Data(contentsOf: legacy.appendingPathComponent("theme.json"))
            if let bundledJSON, bundledJSON == legacyJSON {
                try? FileManager.default.removeItem(at: legacy)
            }
        }
        return directory
    }

    private func uniqueImportedThemeName(_ proposed: String, root: URL) -> String {
        let trimmed = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "Imported Theme" : trimmed
        var existing = Set<String>()
        var directories = [root]
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("TouchControlThemes", isDirectory: true) {
            directories.append(bundled)
        }
        for directory in directories {
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            )) ?? []
            for entry in entries where (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                if let json = themeJSON(in: entry), let name = json["name"] as? String, !name.isEmpty {
                    existing.insert(name)
                } else {
                    existing.insert(entry.lastPathComponent)
                }
            }
        }
        if let selectedOverride = selectedOverrideThemeDirectory(),
           let json = themeJSON(in: selectedOverride),
           let name = json["name"] as? String, !name.isEmpty {
            existing.insert(name)
        }
        var candidate = base
        var suffix = 2
        while existing.contains(candidate) {
            candidate = "\(base) \(suffix)"
            suffix += 1
        }
        return candidate
    }

    private func uniqueThemeFolderName(_ proposed: String, root: URL, excluding excludedFolder: URL? = nil) -> String {
        let fileManager = FileManager.default
        let excludedURL = excludedFolder?.standardizedFileURL
        let excludedPath = excludedURL?.path
        let sourceFolderName = excludedURL?.lastPathComponent
        let existingPaths = Set((try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ))?.compactMap { entry -> String? in
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
            return entry.standardizedFileURL.path
        } ?? [])

        var suffix = 1
        while true {
            let candidate = suffix == 1 ? proposed : "\(proposed) \(suffix)"
            let candidatePath = root.appendingPathComponent(candidate, isDirectory: true).standardizedFileURL.path

            if candidatePath == excludedPath {
                // Keep the current folder only when its name already matches
                // the requested name. If a duplicate suffix lands on the source
                // folder (for example, renaming "Theme 2" to "Theme"), keep
                // searching so the folder itself receives a new name.
                if candidate == sourceFolderName {
                    return candidate
                }
                suffix += 1
                continue
            }

            if !existingPaths.contains(candidatePath) {
                return candidate
            }
            suffix += 1
        }
    }

    private func isBundledTheme(_ theme: LauncherTheme) -> Bool {
        // Built-in includes both app-bundled themes and the ROM's selected
        // override theme. Keep the override read-only even if its resolved
        // directory is outside the app bundle.
        let themeURL = URL(fileURLWithPath: theme.path).standardizedFileURL
        if let overrideURL = selectedOverrideThemeDirectory()?.standardizedFileURL,
           themeURL == overrideURL {
            return true
        }

        guard let resourceRoot = Bundle.main.resourceURL?.standardizedFileURL.path else {
            return false
        }
        let path = themeURL.path
        return path == resourceRoot || path.hasPrefix(resourceRoot + "/")
    }

    private func canDeleteTheme(_ theme: LauncherTheme) -> Bool {
        // ROM-matched override themes are bundled with the app and must use
        // the same read-only row layout as themes inside the app bundle.
        guard !isBundledTheme(theme) else { return false }
        let folderName = URL(fileURLWithPath: theme.path).lastPathComponent
        guard folderName.caseInsensitiveCompare("CLASSIC") != .orderedSame,
              theme.name.caseInsensitiveCompare("CLASSIC") != .orderedSame else { return false }
        let documentsRoot = themesDirectory().standardizedFileURL.path + "/"
        let folderURL = URL(fileURLWithPath: theme.path).standardizedFileURL
        let manifestURL = folderURL.appendingPathComponent("theme.json")
        let belongsToCustomThemes = folderURL.path.hasPrefix(documentsRoot)
        return belongsToCustomThemes &&
            FileManager.default.isWritableFile(atPath: folderURL.path) &&
            FileManager.default.isWritableFile(atPath: manifestURL.path)
    }

    private func renameTheme(_ theme: LauncherTheme, to proposedName: String) {
        guard canDeleteTheme(theme) else { return }
        let newName = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty,
              newName.caseInsensitiveCompare("CLASSIC") != .orderedSame,
              let json = themeJSON(in: URL(fileURLWithPath: theme.path)) else { return }

        // Keep the on-disk folder name in sync with the theme's display name.
        // Strip path/control characters so a rename cannot escape the themes directory.
        let proposedFolderName = String(newName.map {
            $0.isLetter || $0.isNumber || $0 == " " || $0 == "_" || $0 == "-" ? $0 : "_"
        }).trimmingCharacters(in: CharacterSet(charactersIn: " ._"))
        guard !proposedFolderName.isEmpty else { return }

        let fileManager = FileManager.default
        let sourceFolder = URL(fileURLWithPath: theme.path).standardizedFileURL
        let root = themesDirectory().standardizedFileURL

        // Resolve the destination against the source folder's actual parent.
        // This is important for imported folders whose names already have a
        // numeric duplicate suffix (for example, "My Theme 2").
        guard sourceFolder.deletingLastPathComponent().standardizedFileURL == root else {
            NSLog("Touch theme rename skipped: source folder is outside the custom themes directory (%@)", sourceFolder.path)
            return
        }
        let folderName = uniqueThemeFolderName(proposedFolderName, root: root, excluding: sourceFolder)
        let destinationFolder = sourceFolder.deletingLastPathComponent()
            .appendingPathComponent(folderName, isDirectory: true).standardizedFileURL
        let shouldMoveFolder = sourceFolder.path != destinationFolder.path

        var updated = json
        updated["name"] = newName
        do {
            if shouldMoveFolder {
                try fileManager.moveItem(at: sourceFolder, to: destinationFolder)
            }

            do {
                let data = try JSONSerialization.data(withJSONObject: updated, options: [.prettyPrinted])
                try data.write(to: destinationFolder.appendingPathComponent("theme.json"), options: .atomic)
            } catch {
                // Roll the folder move back if updating its manifest fails.
                if shouldMoveFolder {
                    try? fileManager.moveItem(at: destinationFolder, to: sourceFolder)
                }
                throw error
            }

            if selectedTheme == theme.name ||
                UserDefaults.standard.string(forKey: "DmTouchControlThemePath") == sourceFolder.path {
                UserDefaults.standard.set(newName, forKey: "DmTouchControlThemeName")
                UserDefaults.standard.set(destinationFolder.path, forKey: "DmTouchControlThemePath")
            }
            refreshThemes()
        } catch {
            NSLog("Touch theme rename failed for %@ -> %@: %@", sourceFolder.lastPathComponent,
                  destinationFolder.lastPathComponent, error.localizedDescription)
        }
    }

    private func deleteTheme(_ theme: LauncherTheme) {
        guard canDeleteTheme(theme) else { return }
        do {
            if URL(fileURLWithPath: theme.path).lastPathComponent.caseInsensitiveCompare("FOREST") == .orderedSame {
                let marker = themesDirectory().appendingPathComponent(".FOREST.deleted")
                FileManager.default.createFile(atPath: marker.path, contents: Data())
            }
            try FileManager.default.removeItem(at: URL(fileURLWithPath: theme.path))
            if selectedTheme == theme.name {
                if let selectedOverride = selectedOverrideThemeDirectory(),
                   let matching = themes.first(where: { URL(fileURLWithPath: $0.path).standardizedFileURL == selectedOverride.standardizedFileURL }) {
                    selectTheme(matching.path, name: matching.name)
                } else if let classic = themes.first(where: { URL(fileURLWithPath: $0.path).lastPathComponent.caseInsensitiveCompare("CLASSIC") == .orderedSame }) {
                    selectTheme(classic.path, name: classic.name)
                }
            }
            refreshThemes()
        } catch {
            NSLog("Touch theme deletion failed: %@", error.localizedDescription)
        }
    }

    private func themeJSON(in folder: URL) -> [String: Any]? {
        let manifest = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ))?.first { $0.lastPathComponent.caseInsensitiveCompare("theme.json") == .orderedSame }
            ?? folder.appendingPathComponent("theme.json")
        guard let data = try? Data(contentsOf: manifest),
              let object = try? JSONSerialization.jsonObject(with: data),
              let json = object as? [String: Any],
              let palette = json["palette"] as? [String: Any] else { return nil }
        let required = ["idle", "pressed", "outline", "ringFill", "text", "pressedText"]
        for key in required {
            guard let value = palette.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame })?.value as? String else { return nil }
            let hex = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
            guard normalized.range(of: "^[0-9A-Fa-f]{6}$", options: .regularExpression) != nil else { return nil }
        }
        return json
    }

    private func themeListVisibilityChanged(_ isShowing: Bool) {
        if isShowing { refreshThemes() }
    }

    private func refreshThemes() {
        let documentsRoot = themesDirectory()
        let bundledFolders = bundledThemeFolders()
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
        let sortedThemes: [LauncherTheme] = folders.compactMap { folder -> LauncherTheme? in
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let json = themeJSON(in: folder) else { return nil }
            return LauncherTheme(name: (json["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? folder.lastPathComponent,
                                 path: folder.path)
        }.sorted { (left: LauncherTheme, right: LauncherTheme) -> Bool in
            func normalizedThemeName(_ value: String) -> String {
                var name = value.uppercased()
                    .replacingOccurrences(of: "_", with: " ")
                    .replacingOccurrences(of: "-", with: " ")
                for suffix in [" SKIN", " THEME"] where name.hasSuffix(suffix) {
                    name = String(name.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                return name.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            func priority(_ theme: LauncherTheme) -> Int {
                let themeURL = URL(fileURLWithPath: theme.path).standardizedFileURL
                let folder = normalizedThemeName(themeURL.lastPathComponent)
                let display = normalizedThemeName(theme.name)
                let overrideFolder = normalizedThemeName((info("DMOverrideFolder") as? String) ?? "")
                let isSelectedOverridePath = selectedOverrideThemeDirectory()?.standardizedFileURL == themeURL
                // Match by the build's ROM override folder as well as its resolved path.
                // This keeps the ROM-specific theme first even if the bundle path layout changes.
                if isSelectedOverridePath || (!overrideFolder.isEmpty &&
                    (folder == overrideFolder || display == overrideFolder)) { return 0 }
                if folder == "CLASSIC" || display == "CLASSIC" { return 1 }
                // Other themes remain available after the ROM-matched override and CLASSIC.
                return 2
            }
            let leftPriority = priority(left), rightPriority = priority(right)
            if leftPriority != rightPriority { return leftPriority < rightPriority }
            let byName = left.name.localizedCaseInsensitiveCompare(right.name)
            if byName != .orderedSame { return byName == .orderedAscending }
            return left.path.localizedCaseInsensitiveCompare(right.path) == .orderedAscending
        }
        // Mirror the control editor: force this ROM's override to index zero
        // after sorting, with CLASSIC retaining its next-highest priority.
        var orderedThemes = sortedThemes
        if let selectedOverride = selectedOverrideThemeDirectory()?.standardizedFileURL,
           let overrideIndex = orderedThemes.firstIndex(where: {
               URL(fileURLWithPath: $0.path).standardizedFileURL == selectedOverride
           }), overrideIndex != 0 {
            let romOverride = orderedThemes.remove(at: overrideIndex)
            orderedThemes.insert(romOverride, at: 0)
        }
        themes = orderedThemes
        let defaults = UserDefaults.standard
        let path = defaults.string(forKey: "DmTouchControlThemePath")
        if let selected = themes.first(where: { $0.path == path }) {
            selectedTheme = selected.name
        } else if let selectedOverride = selectedOverrideThemeDirectory(),
                  let matchingTheme = themes.first(where: {
                      URL(fileURLWithPath: $0.path).standardizedFileURL == selectedOverride.standardizedFileURL
                  }) {
            defaults.set(matchingTheme.path, forKey: "DmTouchControlThemePath")
            defaults.set(matchingTheme.name, forKey: "DmTouchControlThemeName")
            selectedTheme = matchingTheme.name
        } else if let classic = themes.first(where: {
            URL(fileURLWithPath: $0.path).lastPathComponent.caseInsensitiveCompare("CLASSIC") == .orderedSame
        }) {
            defaults.set(classic.path, forKey: "DmTouchControlThemePath")
            defaults.set(classic.name, forKey: "DmTouchControlThemeName")
            selectedTheme = classic.name
        } else {
            selectedTheme = "CLASSIC"
            defaults.set("CLASSIC", forKey: "DmTouchControlThemeName")
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
        var importedPath: String?
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
                for case let entry as URL in enumerator where entry.lastPathComponent.caseInsensitiveCompare("theme.json") == .orderedSame {
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
            let uniqueName = uniqueImportedThemeName(safeName.isEmpty ? "Imported Theme" : safeName, root: root)
            let folderName = uniqueThemeFolderName(uniqueName, root: root)
            let destination = root.appendingPathComponent(folderName, isDirectory: true)
            let staging = root.appendingPathComponent(".import-\(UUID().uuidString)", isDirectory: true)

            do {
                try fileManager.copyItem(at: candidate, to: staging)
                let stagedFiles = try fileManager.contentsOfDirectory(
                    at: staging, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
                )
                if let manifest = stagedFiles.first(where: {
                    $0.lastPathComponent.caseInsensitiveCompare("theme.json") == .orderedSame
                }) {
                    let canonicalManifest = staging.appendingPathComponent("theme.json")
                    if manifest.lastPathComponent != "theme.json" {
                        try fileManager.moveItem(at: manifest, to: canonicalManifest)
                    }
                    var stagedJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: canonicalManifest)) as? [String: Any] ?? [:]
                    stagedJSON["name"] = uniqueName
                    let normalizedData = try JSONSerialization.data(withJSONObject: stagedJSON, options: [.prettyPrinted])
                    try normalizedData.write(to: canonicalManifest, options: .atomic)
                }
                try fileManager.moveItem(at: staging, to: destination)
                importedName = uniqueName
                importedPath = destination.path
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
            selectTheme(importedPath, name: importedName)
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
