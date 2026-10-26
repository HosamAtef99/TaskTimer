import Foundation
import AppKit
import SwiftUI
import QuickLookThumbnailing

/// One-click tools for a task's After Effects project (task row → folder menu).
@MainActor
enum AEProjectTools {

    private static func js(_ s: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [s], options: [])
        let arr = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(arr.dropFirst().dropLast())
    }

    private static func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }

    /// After Effects must be open; if it isn't, opens the project and asks to try again.
    private static func needAE(_ aep: URL) -> Bool {
        if AfterEffects.isRunning { return true }
        NSWorkspace.shared.open(aep)
        AERenderHelper.ensure()
        Store.shared.flash("Opening After Effects — try again once the project is open")
        return false
    }

    /// Runs `then` once After Effects can take scripts. If it isn't open, starts it in the
    /// background (hidden) first; `then` gets true in that case, so the caller can quit it after.
    private static func withAE(_ aep: URL, then: @escaping (_ launched: Bool) -> Void) {
        if AfterEffects.isRunning { then(false); return }
        guard let appURL = NSWorkspace.shared.urlForApplication(toOpen: aep) else {
            alert("After Effects not found", "No app on this Mac opens “\(aep.lastPathComponent)”.")
            return
        }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = false
        cfg.hides = true
        cfg.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: appURL, configuration: cfg) { _, _ in }
        Store.shared.flash("Starting After Effects in the background (about a minute)…")
        let started = Date()
        func poll() {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if Date().timeIntervalSince(started) > 300 {
                    alert("After Effects didn't start", "Try again, or open After Effects yourself first.")
                    return
                }
                guard AfterEffects.isRunning else { poll(); return }
                AfterEffects.doScript("'ready';", timeout: 15) { result in
                    Task { @MainActor in
                        if case .success(let t) = result, t == "ready" { then(true) } else { poll() }
                    }
                }
            }
        }
        poll()
    }

    /// Opens `aep` in After Effects if another project is open (After Effects asks about
    /// unsaved changes itself), then saves it if it has changes.
    private static func openAndSave(_ aep: URL) -> String {
        """
        var want = \(js(aep.path));
        if (!app.project || !app.project.file || app.project.file.fsName !== want) {
          app.open(new File(want));
        }
        if (!app.project.file || app.project.file.fsName !== want) return "notopen";
        if (app.project.dirty) app.project.save();
        """
    }

    // MARK: Organize

    /// Sorts the loose items at the top of the project panel into numbered folders:
    /// main comps, precomps (used inside other comps), footage, images, PSD & AI, audio,
    /// solids, missing. Items already inside a folder stay where they are. One undo step.
    static func organize(_ aep: URL) {
        guard needAE(aep) else { return }
        let script = """
        (function () {
        \(openAndSave(aep))
          app.beginUndoGroup("TaskTimer: Organize project");
          var root = app.project.rootFolder;
          var bins = {};
          function bin(name) {
            if (bins[name]) return bins[name];
            for (var i = 1; i <= root.numItems; i++) {
              var it = root.item(i);
              if (it instanceof FolderItem && it.name === name) { bins[name] = it; return it; }
            }
            bins[name] = app.project.items.addFolder(name);
            return bins[name];
          }
          var used = {};
          for (var i = 1; i <= app.project.numItems; i++) {
            var c = app.project.item(i);
            if (!(c instanceof CompItem)) continue;
            for (var l = 1; l <= c.numLayers; l++) {
              var src = c.layer(l).source;
              if (src && src instanceof CompItem) used[src.id] = true;
            }
          }
          var loose = [];
          for (var i = 1; i <= root.numItems; i++) loose.push(root.item(i));
          var moved = 0;
          for (var k = 0; k < loose.length; k++) {
            var it = loose[k], dest = null;
            if (it instanceof FolderItem) continue;
            if (it instanceof CompItem) {
              dest = used[it.id] ? "02 Precomps" : "01 Comps";
            } else if (it instanceof FootageItem) {
              var s = it.mainSource;
              if (s instanceof SolidSource) dest = "07 Solids";
              else if (it.footageMissing) dest = "Missing";
              else if (s instanceof FileSource && it.file) {
                var name = decodeURI(it.file.name);
                var ext = name.indexOf(".") > 0 ? name.split(".").pop().toLowerCase() : "";
                if (/^(psd|psb|ai|eps|pdf)$/.test(ext)) dest = "05 PSD & AI";
                else if (/^(wav|mp3|aif|aiff|m4a|aac|ogg|flac)$/.test(ext) || (it.hasAudio && !it.hasVideo)) dest = "06 Audio";
                else if (!s.isStill) dest = "03 Footage";
                else dest = "04 Images";
              }
            }
            if (dest) { it.parentFolder = bin(dest); moved++; }
          }
          app.endUndoGroup();
          return "ok " + moved;
        })();
        """
        AfterEffects.doScript(script, activate: true) { result in
            Task { @MainActor in
                switch result {
                case .success(let text):
                    if text == "notopen" {
                        alert("Couldn't open the project", "Open “\(aep.lastPathComponent)” in After Effects, then try again.")
                    } else {
                        let n = Int(text.split(separator: " ").last ?? "") ?? 0
                        Store.shared.flash(n == 0 ? "The project was already tidy" : "Organized \(n) item\(n == 1 ? "" : "s") into folders (⌘Z in After Effects undoes it)")
                    }
                case .failure(let e):
                    alert("Couldn't organize the project", e.localizedDescription)
                }
            }
        }
    }

    // MARK: Collect

    /// Like After Effects' Collect Files, without After Effects: into
    /// `<Task>/Collect/<Task> <date>/` go a copy of the project, every footage file it uses in
    /// "(Footage)" (same subfolders as in the task folder; files from elsewhere in
    /// "(Footage)/Other Files"), and a report. The copy's footage paths point to those files
    /// (PSD / AI layers keep their layer), with After Effects' relative paths set too, so the
    /// folder also opens on another Mac. The project you're working on isn't changed. If it's
    /// open in After Effects with unsaved changes, it's saved first.
    static func collect(_ aep: URL, taskFolder: URL, taskName: String) {
        let run = { collectFromFile(aep, taskFolder: taskFolder, taskName: taskName) }
        guard AfterEffects.isRunning else { run(); return }
        let save = """
        (function () {
          var want = \(js(aep.path));
          if (app.project && app.project.file && app.project.file.fsName === want && app.project.dirty) app.project.save();
          return "ok";
        })();
        """
        AfterEffects.doScript(save, timeout: 60) { _ in Task { @MainActor in run() } }
    }

    private static func collectFromFile(_ aep: URL, taskFolder: URL, taskName: String) {
        Store.shared.flash("Collecting “\(taskName)”…")
        let stamp: String = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HHmm"
            return f.string(from: Date())
        }()
        let collectRoot = FolderService.folder(in: taskFolder, matching: ["collect"])
            ?? taskFolder.appendingPathComponent("Collect", isDirectory: true)
        let dest = collectRoot.appendingPathComponent("\(FolderService.cleanName(taskName)) \(stamp)", isDirectory: true)

        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try collectWork(aep: aep, taskFolder: taskFolder, collectRoot: collectRoot, dest: dest) }
            Task { @MainActor in
                switch result {
                case .failure(let e):
                    if let e = e as? CollectError, case .unreadable = e {
                        // An old project format: let After Effects do it.
                        collectWithAE(aep, taskFolder: taskFolder, taskName: taskName)
                        return
                    }
                    alert("Couldn't collect the project", e.localizedDescription)
                case .success(let r):
                    let size = ByteCountFormatter.string(fromByteCount: r.bytes, countStyle: .file)
                    Store.shared.flash("Collected \(r.copied) file\(r.copied == 1 ? "" : "s") (\(size))")
                    NSWorkspace.shared.activateFileViewerSelecting([r.project])
                    var notes: [String] = []
                    if !r.missing.isEmpty { notes.append("Missing (not on this Mac), not collected:\n" + r.missing.prefix(12).joined(separator: "\n")) }
                    if !r.failed.isEmpty { notes.append("Couldn't copy:\n" + r.failed.prefix(12).joined(separator: "\n")) }
                    if !notes.isEmpty { alert("Collected into “\(dest.lastPathComponent)”", notes.joined(separator: "\n\n")) }
                }
            }
        }
    }

    enum CollectError: LocalizedError {
        case unreadable, message(String)
        var errorDescription: String? {
            switch self {
            case .unreadable: return "This project file couldn't be read."
            case .message(let m): return m
            }
        }
    }

    struct CollectResult {
        let project: URL
        let copied: Int
        let bytes: Int64
        let missing: [String]
        let failed: [String]
    }

    /// The file work of Collect (runs off the main thread).
    nonisolated private static func collectWork(aep: URL, taskFolder: URL, collectRoot: URL, dest: URL) throws -> CollectResult {
        let fm = FileManager.default
        guard let data = fm.contents(atPath: aep.path), let project = AEPFile(data: data) else { throw CollectError.unreadable }
        let found = project.footage()
        if found.items.isEmpty && found.unreadable > 0 { throw CollectError.unreadable }

        let footageDir = dest.appendingPathComponent("(Footage)", isDirectory: true)
        let projectCopy = dest.appendingPathComponent(aep.lastPathComponent)
        try fm.createDirectory(at: footageDir, withIntermediateDirectories: true)

        let task = taskFolder.standardizedFileURL.path
        let collect = collectRoot.standardizedFileURL.path
        var map: [String: String] = [:]
        var missing: [String] = [], failed: [String] = [], report: [String] = []
        var copied = 0
        var bytes: Int64 = 0
        var otherDirs: [String: String] = [:]       // outside folder → its name in Other Files

        func size(_ u: URL) -> Int64 { Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }

        /// Where a file or folder goes: same place under (Footage) as in the task folder.
        func target(for path: String) -> URL {
            let p = URL(fileURLWithPath: path).standardizedFileURL.path
            if p.hasPrefix(task + "/") && !p.hasPrefix(collect + "/") {
                return footageDir.appendingPathComponent(String(p.dropFirst(task.count + 1)))
            }
            let src = URL(fileURLWithPath: p)
            let parent = src.deletingLastPathComponent().path
            var name = otherDirs[parent] ?? src.deletingLastPathComponent().lastPathComponent
            if otherDirs[parent] == nil {
                let used = Set(otherDirs.values)
                var n = 2
                let base = name
                while used.contains(name) { name = "\(base) \(n)"; n += 1 }
                otherDirs[parent] = name
            }
            return footageDir.appendingPathComponent("Other Files", isDirectory: true)
                .appendingPathComponent(name, isDirectory: true)
                .appendingPathComponent(src.lastPathComponent)
        }

        for item in found.items {
            let src = URL(fileURLWithPath: item.path)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: src.path, isDirectory: &isDir) else {
                missing.append(item.path)
                continue
            }
            let to = target(for: item.path)
            do {
                if item.isFolder || isDir.boolValue {
                    // An image sequence: its files (not subfolders).
                    try fm.createDirectory(at: to, withIntermediateDirectories: true)
                    let files = (try? fm.contentsOfDirectory(at: src, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles])) ?? []
                    var n = 0
                    for f in files where (try? f.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                        let t = to.appendingPathComponent(f.lastPathComponent)
                        if !fm.fileExists(atPath: t.path) { try fm.copyItem(at: f, to: t) }
                        bytes += size(f)
                        n += 1
                    }
                    copied += n
                    report.append("\(item.path)/  (\(n) frames)")
                } else {
                    try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if !fm.fileExists(atPath: to.path) { try fm.copyItem(at: src, to: to) }
                    bytes += size(src)
                    copied += 1
                    report.append(item.path)
                }
                map[item.path] = to.path
            } catch {
                failed.append("\(src.lastPathComponent): \(error.localizedDescription)")
            }
        }

        let (relinked, _) = project.relinked(map, projectPath: projectCopy.path)
        let out = relinked.data()
        // Read it back before saving: every collected path must be there.
        guard let check = AEPFile(data: out) else { throw CollectError.message("The project copy didn't come out right; nothing was changed in your project.") }
        let paths = Set(check.footage().items.map(\.path))
        guard map.values.allSatisfy({ paths.contains($0) }) else {
            throw CollectError.message("The project copy didn't come out right; nothing was changed in your project.")
        }
        try out.write(to: projectCopy)

        var lines = ["Collected \(Date())", "Project: \(aep.path)", "",
                     "Collected (\(copied) files, \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))):"]
        lines += report.map { "  " + $0 }
        if !missing.isEmpty { lines += ["", "Missing:"] + missing.map { "  " + $0 } }
        if !failed.isEmpty { lines += ["", "Couldn't copy:"] + failed.map { "  " + $0 } }
        lines += ["", "Fonts and effects aren't collected."]
        let reportURL = dest.appendingPathComponent("\(aep.deletingPathExtension().lastPathComponent) Report.txt")
        try? lines.joined(separator: "\n").write(to: reportURL, atomically: true, encoding: .utf8)

        return CollectResult(project: projectCopy, copied: copied, bytes: bytes,
                             missing: missing.map { ($0 as NSString).lastPathComponent }, failed: failed)
    }

    /// Old way, through After Effects (for project files this can't read).
    /// If After Effects isn't open, it's started hidden in the background and quit at the end.
    static func collectWithAE(_ aep: URL, taskFolder: URL, taskName: String) {
        withAE(aep) { launched in
            collectList(aep, taskFolder: taskFolder, taskName: taskName, launched: launched)
        }
    }

    private static func collectList(_ aep: URL, taskFolder: URL, taskName: String, launched: Bool) {
        let listScript = """
        (function () {
        \(launched ? "app.beginSuppressDialogs();" : "")
        \(openAndSave(aep))
          var seen = {}, out = [];
          for (var i = 1; i <= app.project.numItems; i++) {
            var it = app.project.item(i);
            if (!(it instanceof FootageItem) || !(it.mainSource instanceof FileSource) || !it.file) continue;
            if (it.footageMissing) { out.push("M\\t" + it.file.fsName); continue; }
            var p = it.file.fsName;
            if (seen[p]) continue;
            seen[p] = true;
            var ext = decodeURI(it.file.name).split(".").pop().toLowerCase();
            var seq = !it.mainSource.isStill && /^(png|jpe?g|tiff?|tga|exr|dpx|bmp|psd)$/.test(ext);
            out.push((seq ? "S" : "F") + "\\t" + p);
          }
          return "ok\\n" + out.join("\\n");
        })();
        """
        Store.shared.flash("Collecting “\(taskName)”…")
        AfterEffects.doScript(listScript, activate: !launched) { result in
            Task { @MainActor in
                switch result {
                case .failure(let e):
                    alert("Couldn't collect the project", e.localizedDescription)
                case .success(let text):
                    if text == "notopen" {
                        alert("Couldn't open the project", "Open “\(aep.lastPathComponent)” in After Effects, then try again.")
                        return
                    }
                    var files: [(path: String, sequence: Bool)] = []
                    var missing: [String] = []
                    // After Effects may hand lines back with \r instead of \n.
                    for line in text.components(separatedBy: .newlines).dropFirst() where !line.isEmpty {
                        let parts = line.components(separatedBy: "\t")
                        guard parts.count == 2 else { continue }
                        switch parts[0] {
                        case "M": missing.append((parts[1] as NSString).lastPathComponent)
                        case "S": files.append((parts[1], true))
                        default: files.append((parts[1], false))
                        }
                    }
                    copyAndRelink(aep: aep, taskFolder: taskFolder, taskName: taskName, files: files, missing: missing, launched: launched)
                }
            }
        }
    }

    private static func copyAndRelink(aep: URL, taskFolder: URL, taskName: String,
                                      files: [(path: String, sequence: Bool)], missing: [String], launched: Bool) {
        let stamp: String = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HHmm"
            return f.string(from: Date())
        }()
        let collectRoot = FolderService.folder(in: taskFolder, matching: ["collect"])
            ?? taskFolder.appendingPathComponent("Collect", isDirectory: true)
        let dest = collectRoot.appendingPathComponent("\(FolderService.cleanName(taskName)) \(stamp)", isDirectory: true)
        let footage = dest.appendingPathComponent("(Footage)", isDirectory: true)
        let projectCopy = dest.appendingPathComponent(aep.lastPathComponent)

        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            var map: [(old: String, new: String, sequence: Bool)] = []
            var failed: [String] = []
            var bytes: Int64 = 0
            do {
                try fm.createDirectory(at: footage, withIntermediateDirectories: true)
                try fm.copyItem(at: aep, to: projectCopy)
            } catch {
                let msg = error.localizedDescription
                Task { @MainActor in alert("Couldn't collect the project", msg) }
                return
            }
            var usedDirs: Set<String> = []
            for f in files {
                let src = URL(fileURLWithPath: f.path)
                // Each file keeps the name of the folder it came from, so same-named files don't clash.
                var dirName = src.deletingLastPathComponent().lastPathComponent
                if f.sequence {
                    var n = 2
                    let base = dirName
                    while usedDirs.contains(dirName) { dirName = "\(base) \(n)"; n += 1 }
                }
                usedDirs.insert(dirName)
                let dir = footage.appendingPathComponent(dirName, isDirectory: true)
                do {
                    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                    if f.sequence {
                        // The whole image sequence: every file with the same extension in its folder.
                        let ext = src.pathExtension.lowercased()
                        let frames = (try? fm.contentsOfDirectory(at: src.deletingLastPathComponent(), includingPropertiesForKeys: [.fileSizeKey])) ?? []
                        for fr in frames where fr.pathExtension.lowercased() == ext {
                            let to = dir.appendingPathComponent(fr.lastPathComponent)
                            if !fm.fileExists(atPath: to.path) { try fm.copyItem(at: fr, to: to) }
                            bytes += Int64((try? fr.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                        }
                    } else {
                        var to = dir.appendingPathComponent(src.lastPathComponent)
                        var n = 2
                        while fm.fileExists(atPath: to.path) {
                            to = dir.appendingPathComponent("\(src.deletingPathExtension().lastPathComponent) \(n).\(src.pathExtension)")
                            n += 1
                        }
                        try fm.copyItem(at: src, to: to)
                        bytes += Int64((try? src.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                        map.append((f.path, to.path, false))
                        continue
                    }
                    map.append((f.path, dir.appendingPathComponent(src.lastPathComponent).path, true))
                } catch {
                    failed.append(src.lastPathComponent)
                }
            }
            let done = map, bad = failed, total = bytes
            Task { @MainActor in
                relink(original: aep, copy: projectCopy, dest: dest, map: done, failed: bad, missing: missing, bytes: total, launched: launched)
            }
        }
    }

    private static func relink(original: URL, copy: URL, dest: URL, map: [(old: String, new: String, sequence: Bool)],
                               failed: [String], missing: [String], bytes: Int64, launched: Bool) {
        let pairs = map.map { "[\(js($0.old)),\(js($0.new)),\($0.sequence)]" }.joined(separator: ",")
        // Started hidden for this: close the copy and quit After Effects. Otherwise reopen the original.
        let finish = launched
            ? "app.project.close(CloseOptions.DO_NOT_SAVE_CHANGES); app.endSuppressDialogs(false); app.scheduleTask('app.quit();', 1500, false);"
            : "app.open(orig);"
        let script = """
        (function () {
          var orig = new File(\(js(original.path)));
          var map = {}, list = [\(pairs)];
          for (var i = 0; i < list.length; i++) map[list[i][0]] = list[i];
          app.open(new File(\(js(copy.path))));
          var done = 0, layered = 0;
          for (var i = 1; i <= app.project.numItems; i++) {
            var it = app.project.item(i);
            if (!(it instanceof FootageItem) || !(it.mainSource instanceof FileSource) || !it.file) continue;
            var m = map[it.file.fsName];
            if (!m) continue;
            // A layer from a layered PSD / AI: scripts can't relink it without losing the layer.
            if (it.name.indexOf("/") > 0 && /\\.(psd|psb|ai)$/i.test(decodeURI(it.file.name))) { layered++; continue; }
            try {
              if (m[2]) it.replaceWithSequence(new File(m[1]), false);
              else it.replace(new File(m[1]));
              done++;
            } catch (e) { }
          }
          app.project.save();
          \(finish)
          return "ok " + done + " " + layered;
        })();
        """
        AfterEffects.doScript(script, activate: !launched) { result in
            Task { @MainActor in
                switch result {
                case .failure(let e):
                    alert("The files were copied, but relinking failed", "\(e.localizedDescription)\n\nThe copy is in \(dest.path).")
                case .success(let text):
                    let parts = text.split(separator: " ")
                    let layered = parts.count > 2 ? Int(parts[2]) ?? 0 : 0
                    var notes: [String] = []
                    if layered > 0 {
                        notes.append("\(layered) PSD/AI layer\(layered == 1 ? "" : "s") still point to the original file (scripts can't relink PSD layers). The PSD itself was copied to (Footage).")
                    }
                    if !missing.isEmpty { notes.append("Missing, not collected: " + missing.prefix(10).joined(separator: ", ")) }
                    if !failed.isEmpty { notes.append("Couldn't copy: " + failed.prefix(10).joined(separator: ", ")) }
                    let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
                    Store.shared.flash("Collected \(map.count) file\(map.count == 1 ? "" : "s") (\(size))")
                    NSWorkspace.shared.activateFileViewerSelecting([dest])
                    if !notes.isEmpty { alert("Collected into “\(dest.lastPathComponent)”", notes.joined(separator: "\n\n")) }
                }
            }
        }
    }
}

// MARK: - Last render thumbnail (task row)

/// A small picture of the newest file in the task's Render folder. Click to open it.
struct RenderThumb: View {
    let folder: URL
    @Local var image: NSImage? = nil
    @Local var file: URL? = nil
    @Local var key = ""

    private static let exts: Set<String> = ["mov", "mp4", "m4v", "png", "jpg", "jpeg", "tif", "tiff", "gif", "webm", "mxf", "avi"]

    var body: some View {
        // Always something on screen (even before there's a picture), so .task runs.
        ZStack {
            Color.clear.frame(width: 0, height: 0)
            if let image, let file {
                Button { NSWorkspace.shared.open(file) } label: {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 64, height: 36)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .help("Last render: \(file.lastPathComponent)")
            }
        }
        .task(id: folder) {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
    }

    private func load() async {
        guard let render = FolderService.folder(in: folder, matching: ["render", "renders", "output"]) else {
            image = nil; file = nil; return
        }
        let found = await Task.detached(priority: .utility) { () -> (URL, Date)? in
            let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
            guard let e = FileManager.default.enumerator(at: render, includingPropertiesForKeys: keys,
                                                         options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return nil }
            var best: (URL, Date)?
            var count = 0
            for case let u as URL in e {
                if e.level > 2 { e.skipDescendants(); continue }
                count += 1
                if count > 3000 { break }
                guard Self.exts.contains(u.pathExtension.lowercased()),
                      let v = try? u.resourceValues(forKeys: Set(keys)), v.isRegularFile == true,
                      let d = v.contentModificationDate else { continue }
                if best == nil || d > best!.1 { best = (u, d) }
            }
            return best
        }.value
        guard let found else { image = nil; file = nil; key = ""; return }
        let (url, date) = found
        let k = url.path + "\(date.timeIntervalSince1970)"
        if k == key && image != nil { return }
        let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 128, height: 72), scale: 2,
                                               representationTypes: .thumbnail)
        if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req) {
            image = rep.nsImage
            file = url
            key = k
        }
    }
}
