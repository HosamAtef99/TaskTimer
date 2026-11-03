import Foundation
import AppKit

/// Replaces "New Project.command": builds the task folder tree (the team's fixed subfolders),
/// puts an empty After Effects project in it, and sorts downloaded files into the right subfolders.
enum FolderService {

    enum FolderError: LocalizedError {
        case exists(String), emptyName

        var errorDescription: String? {
            switch self {
            case .exists(let n): return "A folder named “\(n)” already exists there."
            case .emptyName: return "Task name is empty."
            }
        }
    }

    /// The After Effects versions the app has an empty project for (Resources/Blank-<v>.aep).
    static let aeVersions = ["24", "25", "26"]

    /// The empty After Effects project for the version picked in Settings → Folders, copied into
    /// every new task folder as "<Task>.aep". Nobody picks a template any more (Hosam's call).
    static var blankAEP: URL? {
        let v = Pref.string(Pref.aeVersion)
        guard let u = Bundle.main.url(forResource: "Blank-\(aeVersions.contains(v) ? v : "26")", withExtension: "aep"),
              FileManager.default.fileExists(atPath: u.path) else { return nil }
        return u
    }

    /// "26" when After Effects 2026 is installed, and so on (the newest one found).
    static var newestInstalledAE: String? {
        let fm = FileManager.default
        for v in aeVersions.reversed() where fm.fileExists(atPath: "/Applications/Adobe After Effects 20\(v)") {
            return v
        }
        return nil
    }

    static func cleanName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
    }

    /// Lets the user pick the parent folder, starting at the last location used.
    @MainActor
    static func chooseLocation() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose where to create the task folder"
        let last = Pref.string(Pref.lastLocation)
        if !last.isEmpty, FileManager.default.fileExists(atPath: last) {
            panel.directoryURL = URL(fileURLWithPath: last)
        } else {
            panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        UserDefaults.standard.set(url.path, forKey: Pref.lastLocation)
        return url
    }

    @MainActor
    static func chooseExistingFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        panel.message = "Choose an existing task folder"
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// Creates <base>/<name>/ with the subfolder tree and an empty "<name>.aep" in the AE folder.
    @discardableResult
    static func createProject(name rawName: String, in base: URL) throws -> URL {
        let fm = FileManager.default
        let name = cleanName(rawName)
        guard !name.isEmpty else { throw FolderError.emptyName }

        let project = base.appendingPathComponent(name, isDirectory: true)
        if fm.fileExists(atPath: project.path) { throw FolderError.exists(name) }

        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        for sub in Pref.subfolderList {
            try fm.createDirectory(at: project.appendingPathComponent(sub, isDirectory: true),
                                   withIntermediateDirectories: true)
        }

        if let blank = blankAEP {
            let aeFolder = folder(in: project, matching: ["ae"]) ?? project
            let dest = aeFolder.appendingPathComponent("\(name).aep")
            try fm.copyItem(at: blank, to: dest)
        }
        return project
    }

    // MARK: - Finding subfolders

    /// Finds a direct subfolder whose name contains one of the keywords as a word
    /// (so "AE" matches "01 - AE" but not "06 - Assets and others").
    static func folder(in project: URL, matching keywords: [String]) -> URL? {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: project, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return nil }
        let dirs = items.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for kw in keywords {
            for d in dirs {
                let words = d.lastPathComponent.lowercased()
                    .components(separatedBy: CharacterSet.alphanumerics.inverted)
                    .filter { !$0.isEmpty }
                if words.contains(kw) { return d }
            }
        }
        return nil
    }

    /// The task's After Effects project: the most recently saved .aep / .aepx anywhere in the
    /// task folder (three levels deep), not counting After Effects' Auto-Save copies, collected
    /// copies (the Collect folder) or the Render folder.
    static func aeFile(in project: URL) -> URL? {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .contentModificationDateKey]
        guard let e = FileManager.default.enumerator(at: project, includingPropertiesForKeys: keys,
                                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return nil }
        var best: (URL, Date)?
        var count = 0
        for case let u as URL in e {
            count += 1
            if count > 20000 { break }
            let v = try? u.resourceValues(forKeys: Set(keys))
            if v?.isDirectory == true {
                let words = u.lastPathComponent.lowercased()
                    .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
                if e.level >= 3 || words.contains("collect") || words.contains("render") || words.contains("renders")
                    || u.lastPathComponent.localizedCaseInsensitiveContains("auto-save") {
                    e.skipDescendants()
                }
                continue
            }
            guard v?.isRegularFile == true, ["aep", "aepx"].contains(u.pathExtension.lowercased()) else { continue }
            let d = v?.contentModificationDate ?? .distantPast
            if best == nil || d > best!.1 { best = (u, d) }
        }
        return best?.0
    }

    // MARK: - Sorting downloaded files

    /// Which subfolder each kind of file goes to. A folder matches when its name
    /// contains one of the keywords as a word ("06 - Images" matches "images").
    /// Anything not listed here goes to the "Others" folder.
    static let rules: [(exts: Set<String>, keywords: [String])] = [
        (["psd", "psb", "ai", "eps"],   // Photoshop + Illustrator
         ["psd"]),
        (["aep", "aepx", "aet"],
         ["ae"]),
        (["wav", "mp3", "aif", "aiff", "m4a", "aac", "ogg", "flac", "opus", "wma"],
         ["sound", "sounds", "audio", "sfx", "music"]),
        (["png", "jpg", "jpeg", "tif", "tiff", "gif", "webp", "heic", "heif", "bmp", "tga",
          "exr", "dpx", "svg", "avif", "jfif", "raw", "cr2", "cr3", "nef", "arw", "dng"],
         ["images", "image", "img", "stills", "photos"]),
        (["mov", "mp4", "m4v", "avi", "mkv", "mxf", "webm", "mpg", "mpeg", "wmv", "flv",
          "3gp", "r3d", "braw", "mts", "m2ts", "prores"],
         ["videos", "video", "footage", "footages"]),
    ]

    static let othersKeywords = ["others", "other", "assets", "misc"]

    /// The rule a file belongs to (nil = Others).
    private static func ruleIndex(for url: URL) -> Int? {
        let ext = url.pathExtension.lowercased()
        return rules.firstIndex { $0.exts.contains(ext) }
    }

    /// For a dropped folder: if every file inside is the same kind (e.g. all images),
    /// the whole folder goes there; a mixed folder goes to Others.
    private static func ruleIndex(forFolder dir: URL) -> Int? {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey],
                                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return nil }
        var found: Set<Int> = []
        var count = 0
        for case let f as URL in e {
            guard (try? f.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            count += 1
            guard let r = ruleIndex(for: f) else { return nil }
            found.insert(r)
            if found.count > 1 || count > 2000 { return nil }
        }
        return found.first
    }

    struct Moved { let name: String; let folder: String; let url: URL }

    /// The subfolder of `project` a dropped file or folder belongs in (Others if nothing matches).
    static func target(for src: URL, in project: URL) -> URL {
        let others = folder(in: project, matching: othersKeywords) ?? project
        var isDir: ObjCBool = false
        _ = FileManager.default.fileExists(atPath: src.path, isDirectory: &isDir)
        let r = (isDir.boolValue && src.pathExtension.isEmpty) ? ruleIndex(forFolder: src) : ruleIndex(for: src)
        if let r, let f = folder(in: project, matching: rules[r].keywords) { return f }
        return others
    }

    /// Moves (or copies) each file into its matching subfolder.
    static func sort(_ urls: [URL], into project: URL, copy: Bool = false) -> [Moved] {
        let fm = FileManager.default
        var moved: [Moved] = []

        for src in urls {
            guard fm.fileExists(atPath: src.path) else { continue }
            let target = target(for: src, in: project)

            // Already in place: nothing to move or copy, but it can still be imported.
            if src.deletingLastPathComponent().standardizedFileURL == target.standardizedFileURL {
                moved.append(Moved(name: src.lastPathComponent, folder: target.lastPathComponent, url: src))
                continue
            }
            // Never put a folder into its own child.
            if target.path.hasPrefix(src.path + "/") || target.path == src.path { continue }

            var dest = target.appendingPathComponent(src.lastPathComponent)
            var n = 2
            while fm.fileExists(atPath: dest.path) {
                let base = src.deletingPathExtension().lastPathComponent
                let name = src.pathExtension.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(src.pathExtension)"
                dest = target.appendingPathComponent(name)
                n += 1
            }
            do {
                if copy {
                    try fm.copyItem(at: src, to: dest)
                } else {
                    try fm.moveItem(at: src, to: dest)
                }
                moved.append(Moved(name: dest.lastPathComponent, folder: target.lastPathComponent, url: dest))
            } catch {
                NSLog("TaskTimer sort failed: \(error.localizedDescription)")
            }
        }
        return moved
    }
}
