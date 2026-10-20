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

    /// Opens chrome://extensions (passed to Chrome on its command line, which it accepts
    /// even when it is already running) and shows the extension folder in Finder.
    static func openChromeAndFolder() -> Bool {
        refresh()
        NSWorkspace.shared.activateFileViewerSelecting([folder])
        guard let chrome = chromeURL else { return false }
        let exe = chrome.appendingPathComponent("Contents/MacOS").appendingPathComponent(
            (Bundle(url: chrome)?.object(forInfoDictionaryKey: "CFBundleExecutable") as? String) ?? "Google Chrome")
        let p = Process()
        p.executableURL = exe
        p.arguments = ["chrome://extensions"]
        do {
            try p.run()
        } catch {
            NSWorkspace.shared.open(chrome)
        }
        return true
    }
}

/// Step-by-step help shown with "Add Extension".
struct AddExtensionSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    @ObservedObject var cloud = CloudSync.shared
    @Local var noChrome = false

    var body: some View {
        SheetFrame(title: "Add the Chrome extension", subtitle: "Once — then it updates by itself with TaskTimer",
                   icon: "puzzlepiece.extension.fill") {
            if noChrome {
                Label("Google Chrome wasn't found on this Mac. Install Chrome, then press Open Chrome again.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12)).foregroundStyle(Theme.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 12) {
                step(1, "In the Chrome tab that just opened (chrome://extensions), turn on **Developer mode** — top right.")
                step(2, "Drag the **TaskTimer Chrome Extension** folder from the Finder window onto that Chrome page.\nOr press **Load unpacked**, then ⌘⇧G, paste (the path is copied) and press Select.")
                step(3, "Click the puzzle icon 🧩 in Chrome's toolbar → **TaskTimer for Modhesh**, and sign in with the same account as TaskTimer.")
                step(4, "Stay signed in to Modhesh in Chrome. That's it — TaskTimer shows “Extension connected” within a few minutes.")
            }
            .padding(14)
            .glassCard(radius: 14)

            HStack(spacing: 6) {
                Circle().fill(cloud.extensionConnected ? Theme.green : Color.secondary.opacity(0.4)).frame(width: 8, height: 8)
                Text(cloud.extensionConnected ? "Extension connected ✓" : "Waiting for the extension…")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(cloud.extensionConnected ? Theme.green : .secondary)
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
                try? await Task.sleep(nanoseconds: 10_000_000_000)
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

    private func copyPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ExtensionInstaller.folder.path, forType: .string)
        store.flash("Folder path copied")
    }

    private func open() {
        copyPath()
        noChrome = !ExtensionInstaller.openChromeAndFolder()
    }
}

/// "Add Extension" button + status, used in Settings → Modhesh and the Modhesh window.
struct ExtensionStatusRow: View {
    @ObservedObject var cloud = CloudSync.shared
    @Local var showHelp = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "puzzlepiece.extension.fill")
                .font(.system(size: 18))
                .foregroundStyle(cloud.extensionConnected ? AnyShapeStyle(Theme.green) : AnyShapeStyle(Theme.cool))
            VStack(alignment: .leading, spacing: 2) {
                Text(cloud.extensionConnected ? "Chrome extension connected" : "Chrome extension not added")
                    .font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if cloud.extensionConnected {
                Button("Reinstall…") { showHelp = true }
                    .buttonStyle(GlassButtonStyle(compact: true))
            } else {
                Button { showHelp = true } label: { Label("Add Extension", systemImage: "plus") }
                    .buttonStyle(GradientButtonStyle(compact: true))
            }
        }
        .padding(12)
        .glassCard(radius: 12, highlight: !cloud.extensionConnected)
        .sheet(isPresented: $showHelp) {
            AddExtensionSheet().environmentObject(Store.shared)
        }
    }

    private var detail: String {
        if let d = cloud.extensionSeen, cloud.extensionConnected {
            return "Version \(cloud.extensionVersion ?? "?") · checked in \(Fmt.relative(d))"
        }
        if let d = cloud.extensionSeen {
            return "Last seen \(Fmt.relative(d)) — is Chrome open and the extension signed in?"
        }
        return "Needed to read Modhesh and log your time there."
    }
}
