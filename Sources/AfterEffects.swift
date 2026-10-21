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

    static func importFiles(_ urls: [URL], bin: String, layered kind: LayeredKind = .retainSizes,
                            done: @escaping (Result<Int, Error>) -> Void) {
        let list = items(from: urls)
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
        let entries = list.map { "[\(js($0.path)),\($0.sequence),\($0.layered)]" }.joined(separator: ",")
        let script = """
        (function () {
          var list = [\(entries)];
          var name = \(js(bin));
          if (!app.project) app.newProject();
          app.beginUndoGroup("TaskTimer import");
          var bin = null;
          for (var i = 1; i <= app.project.numItems; i++) {
            var it = app.project.item(i);
            if (it instanceof FolderItem && it.name === name && it.parentFolder.id === app.project.rootFolder.id) { bin = it; break; }
          }
          if (!bin) bin = app.project.items.addFolder(name);
          var n = 0, errs = [];
          // PSD / AI: the chosen kind first, then the others if After Effects refuses it.
          var layeredKinds = [ImportAsType.\(kind.rawValue), ImportAsType.COMP_CROPPED_LAYERS, ImportAsType.COMP, ImportAsType.FOOTAGE];
          for (var k = 0; k < list.length; k++) {
            var f = new File(list[k][0]);
            var kinds = list[k][2] ? layeredKinds : [ImportAsType.FOOTAGE];
            var item = null, last = "";
            for (var j = 0; j < kinds.length && !item; j++) {
              try {
                var io = new ImportOptions(f);
                if (list[k][1]) io.sequence = true;
                if (io.canImportAs(kinds[j])) io.importAs = kinds[j];
                else if (list[k][2]) continue;
                item = app.project.importFile(io);
              } catch (e) { last = e.toString(); }
            }
            if (item) {
              try { item.parentFolder = bin; } catch (e) {}
              n++;
            } else {
              errs.push(decodeURI(f.name) + ": " + (last || "After Effects couldn't import it"));
            }
          }
          app.endUndoGroup();
          return n + "|" + errs.join("\\n");
        })();
        """
        let escaped = script
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        tell application id "\(id)"
            DoScript "\(escaped)"
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

    struct Err: LocalizedError {
        let message: String
        init(_ m: String) { message = m }
        var errorDescription: String? { message }
    }
}
