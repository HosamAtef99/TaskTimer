import Foundation
import AppKit
import SwiftUI

/// The Chrome extension ships inside TaskTimer. It is copied to a fixed folder on this Mac
/// (Chrome loads it from there), and refreshed whenever TaskTimer is updated — the extension
/// notices the new files and reloads itself, so it never needs to be downloaded by hand.
enum ExtensionInstaller {
    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TaskTimer Dev", isDirectory: true)
            .appendingPathComponent("TaskTimer Chrome Extension", isDirectory: true)
    }

    static var bundled: URL? {
        guard let r = Bundle.main.resourceURL?.appendingPathComponent("ChromeExtension", isDirectory: true),
              FileManager.default.fileExists(atPath: r.appendingPathComponent("manifest.json").path) else { return nil }
        return r
    }

    static func version(at dir: URL) -> String? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["version"] as? String
    }

    static var bundledVersion: String? { bundled.flatMap { version(at: $0) } }

    /// Copies the bundled extension into place (file by file, so a loaded copy keeps working).
    @discardableResult
    static func refresh() -> Bool {
        guard let src = bundled else { return false }
        let fm = FileManager.default
        let dest = folder
        try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
        guard let e = fm.enumerator(at: src, includingPropertiesForKeys: [.isDirectoryKey]) else { return false }
        for case let u as URL in e {
            let rel = u.path.replacingOccurrences(of: src.path + "/", with: "")
            let target = dest.appendingPathComponent(rel)
            if (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                try? fm.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            guard let data = try? Data(contentsOf: u) else { continue }
            if let old = try? Data(contentsOf: target), old == data { continue }
            try? data.write(to: target, options: .atomic)
        }
        return true
    }

    static var chromeURL: URL? {
        for id in ["com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary"] {
            if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return u }
        }
        return nil
    }

    enum ChromeResult { case opened, chromeOnly, noChrome }

    /// Chrome doesn't let other apps open chrome:// pages by link or command line, so the
    /// extensions page is opened by asking Chrome itself (AppleScript; macOS asks once for
    /// permission). Also shows the extension folder in Finder.
    static func openChromeAndFolder() -> ChromeResult {
        refresh()
        NSWorkspace.shared.activateFileViewerSelecting([folder])
        guard let chrome = chromeURL else { return .noChrome }
        let name = FileManager.default.displayName(atPath: chrome.path).replacingOccurrences(of: ".app", with: "")
        let source = """
        tell application "\(name)"
            activate
            if (count of windows) = 0 then make new window
            tell front window to make new tab with properties {URL:"chrome://extensions"}
        end tell
        """
        var err: NSDictionary?
        if let script = NSAppleScript(source: source) {
            script.executeAndReturnError(&err)
            if err == nil { return .opened }
            NSLog("TaskTimer: opening chrome://extensions failed: \(err ?? [:])")
        }
        NSWorkspace.shared.openApplication(at: chrome, configuration: NSWorkspace.OpenConfiguration())
        return .chromeOnly
    }
}

/// Step-by-step help shown with "Add Extension".
struct AddExtensionSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    @ObservedObject var cloud = CloudSync.shared
    @ObservedObject var monitor = ExtensionMonitor.shared
    @Local var result: ExtensionInstaller.ChromeResult = .opened

    var body: some View {
        SheetFrame(title: "Add the Chrome extension", subtitle: "Once — then it updates by itself with TaskTimer",
                   icon: "puzzlepiece.extension.fill") {
            switch result {
            case .noChrome:
                Label("Google Chrome wasn't found on this Mac. Install Chrome, then press Open Chrome again.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12)).foregroundStyle(Theme.orange)
                    .fixedSize(horizontal: false, vertical: true)
            case .chromeOnly:
                HStack(spacing: 8) {
                    Label("Chrome didn't open the extensions page. Click Chrome's address bar, paste (⌘V) and press Return — or allow TaskTimer to control Chrome in System Settings → Privacy & Security → Automation, then press Open Chrome again.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12)).foregroundStyle(Theme.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Copy address") { copy("chrome://extensions") }
                        .buttonStyle(GlassButtonStyle(compact: true))
                }
            case .opened:
                EmptyView()
            }
            VStack(alignment: .leading, spacing: 12) {
                step(1, "In the Chrome tab that just opened (chrome://extensions), turn on **Developer mode** — top right.")
                step(2, "Drag the **TaskTimer Chrome Extension** folder from the Finder window onto that Chrome page.\nOr press **Load unpacked**, then ⌘⇧G, paste the path (**Copy Path** below) and press Select.")
                step(3, "Click the puzzle icon 🧩 in Chrome's toolbar → **TaskTimer for Modhesh**, and sign in with the same account as TaskTimer.")
                step(4, "Stay signed in to Modhesh in Chrome. That's it — TaskTimer shows “Extension connected” within a few minutes.")
            }
            .padding(14)
            .glassCard(radius: 14)

            HStack(spacing: 6) {
                let ok = monitor.installed || cloud.extensionConnected
                Circle().fill(ok ? Theme.green : Color.secondary.opacity(0.4)).frame(width: 8, height: 8)
                Text(cloud.extensionConnected ? "Extension connected ✓"
                     : (monitor.installed ? "Added to Chrome ✓ — now sign in to it (step 3)" : "Waiting for the extension…"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(ok ? Theme.green : .secondary)
            }

            HStack(spacing: 8) {
                Button("Open Chrome again") { open() }
                    .buttonStyle(GlassButtonStyle(compact: true))
                Button("Show Folder") { NSWorkspace.shared.activateFileViewerSelecting([ExtensionInstaller.folder]) }
                    .buttonStyle(GlassButtonStyle(compact: true))
                Button("Copy Path") { copyPath() }
                    .buttonStyle(GlassButtonStyle(compact: true))
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(GradientButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: 520)
        .onAppear { open() }
        .task {
            while !Task.isCancelled && !cloud.extensionConnected {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                monitor.check()
                await cloud.loadSettings()
            }
        }
    }

    private func step(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Theme.diagonal, in: Circle())
            Text(text)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func copyPath() {
        copy(ExtensionInstaller.folder.path)
        store.flash("Folder path copied")
    }

    private func open() {
        result = ExtensionInstaller.openChromeAndFolder()
        // If Chrome couldn't be told to open the page, have the address ready to paste.
        if result == .chromeOnly { copy("chrome://extensions") } else { copy(ExtensionInstaller.folder.path) }
    }
}

/// Knows whether the extension has been added to Chrome on this Mac, by reading Chrome's own
/// profile settings (no sign-in or network needed), so "Add Extension" disappears right away.
@MainActor
final class ExtensionMonitor: ObservableObject {
    static let shared = ExtensionMonitor()
    @Published private(set) var installed = false
    private var timer: Timer?

    private init() {
        check()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
    }

    func check() {
        let target = ExtensionInstaller.folder.standardizedFileURL.path
        Task.detached(priority: .utility) {
            let found = Self.scan(target)
            await MainActor.run { if self.installed != found { self.installed = found } }
        }
    }

    nonisolated private static func scan(_ target: String) -> Bool {
        let fm = FileManager.default
        let base = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Google")
        for chrome in ["Chrome", "Chrome Beta", "Chrome Canary"] {
            let root = base.appendingPathComponent(chrome)
            guard let profiles = try? fm.contentsOfDirectory(atPath: root.path) else { continue }
            for p in profiles where p == "Default" || p.hasPrefix("Profile ") {
                for file in ["Secure Preferences", "Preferences"] {
                    let url = root.appendingPathComponent(p).appendingPathComponent(file)
                    guard let data = try? Data(contentsOf: url),
                          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let ext = obj["extensions"] as? [String: Any],
                          let settings = ext["settings"] as? [String: Any] else { continue }
                    for case let e as [String: Any] in settings.values {
                        guard let path = e["path"] as? String else { continue }
                        let full = URL(fileURLWithPath: path).standardizedFileURL.path
                        if full == target || path.hasSuffix("/TaskTimer Chrome Extension") { return true }
                    }
                }
            }
        }
        return false
    }
}

/// Extension status, used in Settings → Modhesh and the Modhesh window. The "Add Extension"
/// button only shows while the extension isn't in Chrome.
struct ExtensionStatusRow: View {
    @ObservedObject var cloud = CloudSync.shared
    @ObservedObject var monitor = ExtensionMonitor.shared
    @Local var showHelp = false

    private var added: Bool { monitor.installed || cloud.extensionConnected }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "puzzlepiece.extension.fill")
                .font(.system(size: 18))
                .foregroundStyle(added ? AnyShapeStyle(Theme.green) : AnyShapeStyle(Theme.cool))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if added {
                Button("Help") { showHelp = true }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
            } else {
                Button { showHelp = true } label: { Label("Add Extension", systemImage: "plus") }
                    .buttonStyle(GradientButtonStyle(compact: true))
            }
        }
        .padding(12)
        .glassCard(radius: 12, highlight: !added)
        .sheet(isPresented: $showHelp) {
            AddExtensionSheet().environmentObject(Store.shared)
        }
        .onAppear { monitor.check() }
    }

    private var title: String {
        if cloud.extensionConnected { return "Chrome extension connected" }
        if monitor.installed { return "Chrome extension added" }
        return "Chrome extension not added"
    }

    private var detail: String {
        if let d = cloud.extensionSeen, cloud.extensionConnected {
            return "Version \(cloud.extensionVersion ?? "?") · checked in \(Fmt.relative(d))"
        }
        if monitor.installed {
            return "Sign in to it with your TaskTimer account: click 🧩 in Chrome → TaskTimer for Modhesh."
        }
        return "Needed to read Modhesh and log your time there."
    }
}
