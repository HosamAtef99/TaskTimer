import Foundation
import AppKit

/// Imports files into the After Effects project that's open right now (AppleScript → DoScript).
/// macOS asks once for permission to control After Effects.
enum AfterEffects {

    /// The After Effects app that's running, if any (any version).
    static var running: NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            ($0.bundleIdentifier ?? "").hasPrefix("com.adobe.AfterEffects") && $0.activationPolicy == .regular
        }
    }

    static var isRunning: Bool { running != nil }

    /// Files AE can't (or shouldn't) import from a drop.
    private static let skip: Set<String> = ["aep", "aepx", "aet", "zip", "rar", "7z", "txt", "pdf", "doc", "docx", "xls", "xlsx"]
    private static let layered: Set<String> = ["psd", "psb", "ai", "eps"]
    private static let stills: Set<String> = ["png", "jpg", "jpeg", "tif", "tiff", "tga", "exr", "dpx", "bmp"]

    struct Item { let path: String; let sequence: Bool; let layered: Bool }

    /// What to import from the moved files. A dropped folder of numbered stills comes in as
    /// one image sequence; any other folder brings in the files inside it.
    static func items(from urls: [URL]) -> [Item] {
        let fm = FileManager.default
        var out: [Item] = []
        for u in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: u.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let files = ((try? fm.contentsOfDirectory(at: u, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
                    .filter { !$0.hasDirectoryPath }
                    .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                let allStills = !files.isEmpty && files.allSatisfy { stills.contains($0.pathExtension.lowercased()) }
                let numbered = files.filter { $0.deletingPathExtension().lastPathComponent.last?.isNumber == true }.count
                if allStills && files.count > 2 && numbered == files.count {
                    out.append(Item(path: files[0].path, sequence: true, layered: false))
                } else {
                    out += items(from: Array(files.prefix(200)))
                }
            } else {
                let ext = u.pathExtension.lowercased()
                if skip.contains(ext) { continue }
                out.append(Item(path: u.path, sequence: false, layered: layered.contains(ext)))
            }
        }
        return out
    }

    static func canImport(_ urls: [URL]) -> Bool { !items(from: urls).isEmpty }

    private static let queue = DispatchQueue(label: "TaskTimer.AfterEffects")

    /// Imports into the open project, into a project folder named `bin` (made if missing).
    /// Calls back on the main thread with how many came in, or an error.
    /// How PSD / AI files come in — the same choices as After Effects' own import window.
    enum LayeredKind: String, CaseIterable, Identifiable {
        case retainSizes = "COMP_CROPPED_LAYERS"
        case composition = "COMP"
        case footage = "FOOTAGE"
        var id: String { rawValue }
        var title: String {
            switch self {
            case .retainSizes: return "Composition - Retain Layer Sizes"
            case .composition: return "Composition"
            case .footage: return "Footage (merged layers)"
            }
        }
        static var last: LayeredKind {
            get { LayeredKind(rawValue: UserDefaults.standard.string(forKey: "aeLayeredKind") ?? "") ?? .retainSizes }
            set { UserDefaults.standard.set(newValue.rawValue, forKey: "aeLayeredKind") }
        }
    }

    static func hasLayered(_ urls: [URL]) -> Bool { items(from: urls).contains { $0.layered } }

    /// Imports everything in ONE After Effects script, so a window After Effects opens itself
    /// (its PSD import window) just pauses the script instead of blocking the next one.
    /// Plain files first, PSD / AI last. Each group goes into a project folder named `bin`.
    static func importFiles(_ groups: [(bin: String, urls: [URL])], layered kind: LayeredKind = .retainSizes,
                            activate: Bool = true,
                            done: @escaping (Result<Int, Error>) -> Void) {
        let all = groups.flatMap { g in items(from: g.urls).map { (g.bin, $0) } }
        let list = all.filter { !$0.1.layered } + all.filter { $0.1.layered }
        guard let app = running, let id = app.bundleIdentifier else {
            done(.failure(Err("After Effects isn't open.")))
            return
        }
        guard !list.isEmpty else { done(.success(0)); return }

        func js(_ s: String) -> String {
            let data = try? JSONSerialization.data(withJSONObject: [s], options: [])
            let arr = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
            return String(arr.dropFirst().dropLast())
        }
        let entries = list.map { "[\(js($0.1.path)),\($0.1.sequence),\($0.1.layered),\(js($0.0))]" }.joined(separator: ",")
        let script = """
        (function () {
          var list = [\(entries)];
          if (!app.project) app.newProject();
          var bins = {};
          function binFor(name) {
            if (bins[name]) return bins[name];
            for (var i = 1; i <= app.project.numItems; i++) {
              var it = app.project.item(i);
              if (it instanceof FolderItem && it.name === name && it.parentFolder.id === app.project.rootFolder.id) { bins[name] = it; return it; }
            }
            bins[name] = app.project.items.addFolder(name);
            return bins[name];
          }
          // Never touch what's already in the project: only items this import made are moved
          // into the folder, and a new item whose name is taken gets " (new)" added.
          function snapshot() {
            var ids = {}, names = {}, files = {};
            for (var i = 1; i <= app.project.numItems; i++) {
              var it = app.project.item(i);
              ids[it.id] = true;
              names[it.name] = true;
              try { if (it instanceof FootageItem && it.file) files[it.file.fsName] = true; } catch (e) {}
            }
            return { ids: ids, names: names, files: files };
          }
          app.beginUndoGroup("TaskTimer import");
          var n = 0, errs = [], skipped = [];
          for (var k = 0; k < list.length; k++) {
            var f = new File(list[k][0]);
            var before = snapshot();
            if (before.files[f.fsName]) { skipped.push(decodeURI(f.name)); continue; }
            try {
              var io = new ImportOptions(f);
              if (list[k][1]) io.sequence = true;
              var kind = list[k][2] ? ImportAsType.\(kind.rawValue) : ImportAsType.FOOTAGE;
              if (io.canImportAs(kind)) io.importAs = kind;
              var item = app.project.importFile(io);
              if (!item) continue;
              var bin = binFor(list[k][3]);
              var made = [];
              for (var i = 1; i <= app.project.numItems; i++) {
                var it = app.project.item(i);
                if (!before.ids[it.id] && it.id !== bin.id) made.push(it);
              }
              for (var j = 0; j < made.length; j++) {
                var it = made[j];
                if (it.parentFolder.id !== app.project.rootFolder.id) continue;
                if (before.names[it.name]) it.name = it.name + " (new)";
                try { it.parentFolder = bin; } catch (e) {}
              }
              n++;
            } catch (e) {
              var m = e.toString();
              if (!/cancel/i.test(m)) errs.push(decodeURI(f.name) + ": " + m);
            }
          }
          if (skipped.length) errs.push("Already in the project, not imported again: " + skipped.join(", "));
          app.endUndoGroup();
          return n + "|" + errs.join("\\n");
        })();
        """
        // A PSD / AI may open After Effects' own import window, which has to be seen.
        let bringFront = activate || list.contains { $0.1.layered }
        let escaped = script
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        tell application id "\(id)"
            \(bringFront ? "activate" : "")
            with timeout of 3600 seconds
                DoScript "\(escaped)"
            end timeout
        end tell
        """

        queue.async {
            var err: NSDictionary?
            let result = NSAppleScript(source: source)?.executeAndReturnError(&err)
            DispatchQueue.main.async {
                if let err {
                    let code = err[NSAppleScript.errorNumber] as? Int
                    if code == -1743 {
                        done(.failure(Err("TaskTimer isn't allowed to control After Effects. Turn it on in System Settings → Privacy & Security → Automation → TaskTimer Dev.")))
                    } else if code == -1712 {
                        done(.failure(Err("After Effects didn't answer in time.")))
                    } else {
                        let msg = err[NSAppleScript.errorMessage] as? String ?? "After Effects didn't answer."
                        done(.failure(Err(msg)))
                    }
                    return
                }
                let text = result?.stringValue ?? ""
                let parts = text.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
                let n = Int(parts.first ?? "") ?? list.count
                if parts.count > 1, !parts[1].isEmpty {
                    // Show what didn't come in, even when the rest did.
                    done(.failure(Err((n > 0 ? "\(n) imported. Not imported:\n" : "") + String(parts[1]))))
                } else {
                    done(.success(n))
                }
            }
        }
    }

    /// Runs ExtendScript in the running After Effects. `done` gets the script's result (a
    /// string) or an error, on the main thread. Only for things the person just asked for:
    /// a DoScript while After Effects shows a window of its own makes it show an error.
    static func doScript(_ js: String, timeout: Int = 600, activate: Bool = false,
                         done: @escaping (Result<String, Error>) -> Void) {
        guard let app = running, let id = app.bundleIdentifier else {
            done(.failure(Err("After Effects isn't open.")))
            return
        }
        let escaped = js
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        tell application id "\(id)"
            \(activate ? "activate" : "")
            with timeout of \(timeout) seconds
                DoScript "\(escaped)"
            end timeout
        end tell
        """
        queue.async {
            var err: NSDictionary?
            let result = NSAppleScript(source: source)?.executeAndReturnError(&err)
            let text = result?.stringValue ?? ""
            let code = err?[NSAppleScript.errorNumber] as? Int
            let msg = err?[NSAppleScript.errorMessage] as? String
            DispatchQueue.main.async {
                if err == nil { done(.success(text)); return }
                if code == -1743 {
                    done(.failure(Err("TaskTimer isn't allowed to control After Effects. Turn it on in System Settings → Privacy & Security → Automation → TaskTimer Dev.")))
                } else if code == -1712 {
                    done(.failure(Err("After Effects didn't answer in time.")))
                } else {
                    done(.failure(Err(msg ?? "After Effects didn't answer.")))
                }
            }
        }
    }

    struct Err: LocalizedError {
        let message: String
        init(_ m: String) { message = m }
        var errorDescription: String? { message }
    }
}
