import Foundation
import AppKit
import SwiftUI

/// "Auto-import Downloads" (`Pref.autoImportDownloads`, switched from the header button or
/// Settings → General): while it's on, every new file that finishes downloading into
/// ~/Downloads is moved into the right subfolder of the task whose timer is running (same
/// sorting as dropping files on a task), then imported into the project open in After Effects.
/// Files already in Downloads when it's switched on are left alone.
@MainActor
final class DownloadsWatcher: ObservableObject {
    static let shared = DownloadsWatcher()

    @Published private(set) var isOn = Pref.bool(Pref.autoImportDownloads)

    private var timer: Timer?
    private var known: Set<String> = []                 // names seen (and handled or ignored)
    private var pending: [String: (size: Int64, stable: Int)] = [:]
    private var lastNoTaskNote = Date.distantPast

    private var folder: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }

    /// Still downloading (Chrome, Safari, Firefox, Edge, Opera) or not a real file.
    private static let partial: Set<String> = ["crdownload", "download", "part", "partial", "tmp", "opdownload", "!ut"]

    func start() {
        if isOn { begin() }
    }

    func set(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Pref.autoImportDownloads)
        isOn = on
        if on {
            begin()
            Store.shared.flash("Auto-import on: new downloads go to the running task and into After Effects")
        } else {
            timer?.invalidate()
            timer = nil
            Store.shared.flash("Auto-import off")
        }
    }

    private func begin() {
        known = Set(names())
        pending = [:]
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { @MainActor in DownloadsWatcher.shared.scan() }
        }
    }

    private func names() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.filter { !$0.hasPrefix(".") } ?? []
    }

    private static func size(_ url: URL) -> Int64 {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return -1 }
        if !isDir.boolValue {
            return Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        // A folder (an unzipped download): total of what's inside.
        var total: Int64 = 0
        if let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let f as URL in e { total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        }
        return total
    }

    private func scan() {
        guard isOn else { return }
        let now = names()
        let downloading = now.contains { Self.partial.contains(($0 as NSString).pathExtension.lowercased()) }
        for name in now where !known.contains(name) {
            let ext = (name as NSString).pathExtension.lowercased()
            if Self.partial.contains(ext) { continue }      // wait for the final name
            let size = Self.size(folder.appendingPathComponent(name))
            if let p = pending[name], p.size == size, size > 0 {
                pending[name] = (size, p.stable + 1)
            } else {
                pending[name] = (size, 0)
            }
        }
        // Gone before being handled (moved or deleted by hand).
        pending = pending.filter { now.contains($0.key) }

        // Ready: same size for two checks (4 s). Wait while anything is still downloading,
        // so a batch of downloads goes in together.
        let ready = pending.filter { $0.value.stable >= 2 }.map(\.key)
        guard !ready.isEmpty, !downloading || ready.count == pending.count else { return }
        for n in ready { pending[n] = nil; known.insert(n) }
        handle(ready.sorted().map { folder.appendingPathComponent($0) })
    }

    private func handle(_ files: [URL]) {
        let store = Store.shared
        guard let running = store.running else {
            if Date().timeIntervalSince(lastNoTaskNote) > 60 {
                lastNoTaskNote = Date()
                store.notify(title: "Download left in Downloads",
                             body: "\(files.first?.lastPathComponent ?? "") — start a task's timer so new downloads go to its folder.")
            }
            return
        }
        let task = running.parentID.flatMap { store.task($0) } ?? running
        guard let projectFolder = task.folderURL else {
            store.flash("“\(task.name)” has no folder — the download stayed in Downloads")
            return
        }
        let moved = FolderService.sort(files, into: projectFolder, copy: false)
        guard !moved.isEmpty else { return }
        let summary = Dictionary(grouping: moved, by: { $0.folder })
            .map { "\($0.value.count) → \($0.key)" }
            .sorted()
            .joined(separator: ",  ")
        store.flash("Downloaded into “\(task.name)”: \(summary)")

        guard AfterEffects.isRunning, AfterEffects.canImport(moved.map(\.url)) else { return }
        let groups = Dictionary(grouping: moved, by: { $0.folder })
            .sorted { $0.key < $1.key }
            .map { (bin: $0.key, urls: $0.value.map(\.url)) }
        AfterEffects.importFiles(groups, layered: AfterEffects.LayeredKind.last, activate: false) { result in
            Task { @MainActor in
                switch result {
                case .success(let n):
                    if n > 0 { store.flash("Imported \(n) download\(n == 1 ? "" : "s") into After Effects") }
                case .failure(let e):
                    store.notify(title: "Downloaded, but not imported into After Effects", body: e.localizedDescription)
                }
            }
        }
    }
}

/// Header button: switches auto-import of downloads on and off.
struct DownloadsToggleButton: View {
    @ObservedObject var watcher = DownloadsWatcher.shared

    var body: some View {
        Button { watcher.set(!watcher.isOn) } label: {
            Image(systemName: watcher.isOn ? "arrow.down.circle.fill" : "arrow.down.circle")
        }
        .buttonStyle(CircleIconButtonStyle(filled: watcher.isOn))
        .help(watcher.isOn
              ? "Auto-import is on: new downloads go to the running task's folder and into After Effects. Click to turn off."
              : "Auto-import downloads: new files in Downloads go to the running task's folder and into After Effects")
    }
}
