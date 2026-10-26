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

    /// Like After Effects' Collect Files, into `<Task>/Collect/<Task> <date>/`: a copy of the
    /// project plus every footage file it uses in "(Footage)", relinked to those copies. The
    /// project you're working on isn't changed (it's saved first, then reopened at the end).
    static func collect(_ aep: URL, taskFolder: URL, taskName: String) {
        guard needAE(aep) else { return }
        let listScript = """
        (function () {
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
        AfterEffects.doScript(listScript, activate: true) { result in
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
                    for line in text.components(separatedBy: "\n").dropFirst() {
                        let parts = line.components(separatedBy: "\t")
                        guard parts.count == 2 else { continue }
                        switch parts[0] {
                        case "M": missing.append((parts[1] as NSString).lastPathComponent)
                        case "S": files.append((parts[1], true))
                        default: files.append((parts[1], false))
                        }
                    }
                    copyAndRelink(aep: aep, taskFolder: taskFolder, taskName: taskName, files: files, missing: missing)
                }
            }
        }
    }

    private static func copyAndRelink(aep: URL, taskFolder: URL, taskName: String,
                                      files: [(path: String, sequence: Bool)], missing: [String]) {
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
                relink(original: aep, copy: projectCopy, dest: dest, map: done, failed: bad, missing: missing, bytes: total)
            }
        }
    }

    private static func relink(original: URL, copy: URL, dest: URL, map: [(old: String, new: String, sequence: Bool)],
                               failed: [String], missing: [String], bytes: Int64) {
        let pairs = map.map { "[\(js($0.old)),\(js($0.new)),\($0.sequence)]" }.joined(separator: ",")
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
          app.open(orig);
          return "ok " + done + " " + layered;
        })();
        """
        AfterEffects.doScript(script, activate: true) { result in
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
        Group {
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
