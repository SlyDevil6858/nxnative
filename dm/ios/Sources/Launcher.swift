// Launcher: the settings screen shown before the game starts (front_ios.m dm_show_launcher). Its settings come from the app's dm/launcher.json (an app of several programs: dm/p<N>/launcher.json), which build_ipa.sh writes for this game
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

private extension UIImage {
    func launcherDominantColor() -> UIColor? {
        guard let cg = cgImage else { return nil }
        let w = 32, h = 32, bpp = 4, strideBytes = w * bpp
        var pixels = [UInt8](repeating: 0, count: h * strideBytes)
        let ok = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: strideBytes, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .low
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        struct Bucket { var n = 0; var r = 0; var g = 0; var b = 0 }
        var buckets: [Int: Bucket] = [:]
        for i in stride(from: 0, to: pixels.count, by: bpp) {
            let r = Int(pixels[i]), g = Int(pixels[i+1]), b = Int(pixels[i+2])
            let brightness = (r*299 + g*587 + b*114)/1000
            guard pixels[i+3] > 64, brightness > 18, brightness < 248, max(r,g,b)-min(r,g,b) > 18 else { continue }
            let key = ((r >> 3) << 10) | ((g >> 3) << 5) | (b >> 3)
            var v = buckets[key, default: Bucket()]
            v.n += 1; v.r += r; v.g += g; v.b += b; buckets[key] = v
        }
        guard let d = buckets.values.max(by: { $0.n < $1.n }), d.n > 0 else { return .systemBlue }
        return UIColor(red: CGFloat(d.r)/CGFloat(d.n*255), green: CGFloat(d.g)/CGFloat(d.n*255),
                       blue: CGFloat(d.b)/CGFloat(d.n*255), alpha: 1)
    }
}
/// Load the app icon once. App-icon catalog images are not reliably available through UIImage(named:).
private func loadLauncherAppIcon() -> UIImage? {
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

/// The icon and its derived accent are immutable for this app process.
/// Static initialization ensures the image is decoded and its 32×32 colour
/// sample is calculated at most once, even as SwiftUI repeatedly updates views.
private enum LauncherArtworkCache {
    static let appIcon = loadLauncherAppIcon()
    static let accentColor: Color = {
        guard launcherUsesDominantAccent() else {
            return Color(uiColor: launcherCustomAccentColor() ?? .systemBlue)
        }
        return Color(uiColor: appIcon?.launcherDominantColor() ?? .systemBlue)
    }()
}

private func launcherAppIcon() -> UIImage? {
    LauncherArtworkCache.appIcon
}

/// Dominant accent is enabled by default; a build may explicitly disable it.
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

/// Return the cached accent. Dominant-colour analysis runs only once per process.
private func launcherAccentColor() -> Color {
    LauncherArtworkCache.accentColor
}
private func launcherSupportURL() -> URL? {
    guard let raw = info("DMSupportURL") as? String else { return nil }
    let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: s), let scheme = url.scheme?.lowercased(),
          scheme == "https" || scheme == "http", url.host != nil else { return nil }
    return url
}



/// Cloud saves: an iCloud Drive folder shared with the Mac app (chosen in its settings window's
/// Cloud saves too). The host brings the save in from there when the game starts and
/// sends it there after each save (dm/host/save_sync.h); the folder is a bookmark (CloudSaves.m).
private struct CloudSavesSection: View {
    let checking: Bool
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
            Button(folder.isEmpty ? "Choose a folder in iCloud Drive…" : "Choose a different folder…") { picking = true }
                .disabled(checking)
                // The sheet sits on the button, not on the Section: SwiftUI hands a Section's modifiers to every row, so one tap presented a picker per row and they invalidated each other (LNPANDY/NX2Apple#315).
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
            if !folder.isEmpty {
                Button("Turn off cloud saves", role: .destructive) {
                    dm_clear_cloud_saves(); refresh(); note = ""
                }
                .disabled(checking)
            }
        } footer: {
            Text(note.isEmpty
                 ? "Choose a folder in iCloud Drive, and the same one in the Mac app's Cloud saves. The save comes in when the game starts and goes out after each save; a save that is replaced is kept in save-backups."
                 : note)
        }
        .onAppear(perform: refresh)
    }

    private func refresh() {
        var stale: ObjCBool = false
        folder = dm_cloud_saves_path(&stale) ?? ""
        if stale.boolValue && folder.isEmpty {
            note = "The folder you chose before is no longer readable. Please choose it again."
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

private struct LauncherView: View {
    @ObservedObject var m: LauncherModel
    let play: () -> Void
    @State private var memory = os_proc_available_memory()
    @State private var importingTouchTheme = false
    @State private var touchThemeImportMessage = ""

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
                    Text("Version \\((info("CFBundleShortVersionString") as? String) ?? "") · Build \\((info("CFBundleVersion") as? String) ?? "1")")
                        .font(.callout).foregroundStyle(.secondary)
                    playButton
                }
                .padding(16)
                .frame(width: geometry.size.width / 3, height: geometry.size.height)
                List {
                    ForEach(m.sections, id: \.self) { section in
                        if section == "Performance", let supportURL = launcherSupportURL() {
                            Section("Support") {
                                Button("Support the author of this port…") { UIApplication.shared.open(supportURL) }
                                    .tint(accentColor)
                            }
                        }
                        let rows = m.rows(in: section)
                        if !rows.isEmpty {
                            Section(section) {
                                ForEach(rows) { SettingRow(s: $0, m: m, accentColor: accentColor) }
                                if section == "Controls" {
                                    Button("Edit touch controls layout…") { dm_gamepad_present_launcher_editor() }
                                        .tint(accentColor)
                                    Button("Import touch controls theme…") { importingTouchTheme = true }
                                        .tint(accentColor)
                                    (Text("QUICK TIP: ").fontWeight(.bold).foregroundColor(Color(red: 245.0 / 255.0, green: 176.0 / 255.0, blue: 15.0 / 255.0))
                                     + Text("During gameplay, press and hold the 2D, 3D, or Tap button, or hold Select on your controller, to open the in-game control menu.")
                                        .foregroundColor(Color(white: 0.58)))
                                        .font(.footnote)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .padding(12)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                    }
                    if !m.sections.contains("Performance"), let supportURL = launcherSupportURL() {
                        Section("Support") {
                            Button("Support the author of this port…") { UIApplication.shared.open(supportURL) }
                                .tint(accentColor)
                        }
                    }
                    Section {
                        Button("Reset to tested defaults") { m.reset() }
                            .disabled(!m.changed)
                    } footer: {
                        Text("Brings back all settings this game was tested with.")
                    }
                    // The background save check reads the selected folder until it returns.
                    CloudSavesSection(checking: false)
                    Section {
                        HStack {
                            Text("Memory available")
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: Int64(memory), countStyle: .memory)).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .listRowBackground(Color(red: 23.0 / 255.0, green: 23.0 / 255.0, blue: 23.0 / 255.0))
                .tint(accentColor)
                .fileImporter(isPresented: $importingTouchTheme, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
                    importTouchTheme(result)
                }
                .alert("Touch controls theme", isPresented: Binding(
                    get: { !touchThemeImportMessage.isEmpty },
                    set: { if !$0 { touchThemeImportMessage = "" } }
                )) {
                    Button("OK") { touchThemeImportMessage = "" }
                } message: { Text(touchThemeImportMessage) }
                .contentMargins(.horizontal, 12, for: .scrollContent)
                .frame(width: geometry.size.width * 2 / 3)
            }
        }
        // Keep the artwork outside the HStack/List so drawer updates cannot move it.
        .background {
            if let background = launcherBackground() {
                Image(uiImage: background).resizable().scaledToFill()
                    .overlay(.black.opacity(0.48))
                    .ignoresSafeArea()
            }
        }
        .preferredColorScheme(.dark)
        .task {
            while !Task.isCancelled {
                memory = os_proc_available_memory()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    @ViewBuilder var playButton: some View {
        let button = Button(action: play) {
            Text("Play").font(.title3.weight(.semibold)).frame(maxWidth: 220)
        }.controlSize(.large).tint(accentColor)
        if #available(iOS 26.0, *) { button.buttonStyle(.glassProminent) } else { button.buttonStyle(.borderedProminent) }
    }

    private func launcherBackground() -> UIImage? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("dm/launcher-custom-background.png") else { return nil }
        let screen = UIScreen.main
        let maxPixelSize = max(screen.bounds.width, screen.bounds.height) * screen.scale
        return loadLauncherImage(at: url, maxPixelSize: maxPixelSize)
    }

    private var accentColor: Color { launcherAccentColor() }

    private func importTouchTheme(_ result: Result<[URL], Error>) {
        do {
            guard let source = try result.get().first else { return }
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            guard FileManager.default.fileExists(atPath: source.appendingPathComponent("theme.json").path) else {
                touchThemeImportMessage = "The selected folder does not contain a theme.json file."
                return
            }
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let root = docs.appendingPathComponent("TouchControlThemes", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let raw = source.lastPathComponent
            let safe = String(raw.map { $0.isLetter || $0.isNumber || $0 == " " || $0 == "_" || $0 == "-" ? $0 : "_" })
                .trimmingCharacters(in: CharacterSet(charactersIn: " ._"))
            let base = safe.isEmpty ? "Imported Theme" : safe
            var name = base
            var destination = root.appendingPathComponent(name, isDirectory: true)
            var suffix = 2
            while FileManager.default.fileExists(atPath: destination.path) {
                name = "\(base) \(suffix)"
                destination = root.appendingPathComponent(name, isDirectory: true)
                suffix += 1
            }
            try FileManager.default.copyItem(at: source, to: destination)
            touchThemeImportMessage = "\(name) was imported into TouchControlThemes."
        } catch {
            touchThemeImportMessage = "Could not import the theme: \(error.localizedDescription)"
        }
    }

    private func appIcon() -> UIImage? {
        launcherAppIcon()
    }
}

// Shows the launcher over the root view controller and calls done once the settings are in the environment; false (done is not called) when there is no launcher
@_cdecl("dm_show_launcher")
public func dmShowLauncher(_ viewController: UnsafeMutableRawPointer, _ done: @convention(c) () -> Void) -> Bool {
    // a game of several programs (main.m): the running program's settings, in its dm/p<N>
    let dir = getenv("DM_APP_DM").map { URL(fileURLWithPath: String(cString: $0)) } ?? Bundle.main.resourceURL?.appendingPathComponent("dm")
    guard let url = dir?.appendingPathComponent("launcher.json"), let data = try? Data(contentsOf: url) else { return false }
    guard let file = try? JSONDecoder().decode(SettingsFile.self, from: data), !file.settings.isEmpty else { fputs("[RED] launcher: dm/launcher.json cannot be read; starting the game\n", stderr); return false }
    let model = LauncherModel(file.settings)
    if ProcessInfo.processInfo.environment["DM_LAUNCHER"] == "0" { fputs("launcher: off (DM_LAUNCHER=0)\n", stderr); model.applySaved(); return false }
    let parent = Unmanaged<UIViewController>.fromOpaque(viewController).takeUnretainedValue()
    var host: UIViewController?
    let view = LauncherView(m: model) {
        guard let h = host else { return }
        host = nil
        model.apply()
        h.dismiss(animated: false) { done() }
    }
    let h = UIHostingController(rootView: view)
    h.modalPresentationStyle = .fullScreen
    host = h
    parent.present(h, animated: false)
    fputs("launcher: \(file.settings.count) settings shown\n", stderr)
    return true
}
