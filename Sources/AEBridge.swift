import Foundation
import AppKit

/// TaskTimer's helper inside After Effects, as a small invisible CEP extension
/// ("TaskTimer Helper", copied by TaskTimer into ~/Library/Application Support/Adobe/CEP/extensions).
///
/// Why: a script sent to After Effects with AppleScript (DoScript), or run by
/// `app.scheduleTask`, while one of After Effects' own windows is open (Composition Settings,
/// Save, Interpret Footage…) makes After Effects show "Cannot run a script while a modal dialog
/// is waiting for response". The extension runs in its own browser engine inside After Effects:
/// it talks to After Effects with `evalScript`, which just waits (or is retried) while a window
/// is open, and it reads and writes files with Node.
///
/// It talks to TaskTimer through files in `~/Library/Application Support/TaskTimer Dev/AE/`:
///   • `alive`        — written every second while the extension runs
///   • `state.txt`    — the open project's path + time (the timer follows it)
///   • `config.json`  — TaskTimer's settings (render folder / names)
///   • `requests/<id>.jsx` → `<id>.result` — scripts TaskTimer wants run (imports, collect…)
/// Every 2 s it also runs `TaskTimerTick` (render queue outputs → the task's Render folder).
/// After Effects loads new extensions when it starts, so it has to be restarted once after
/// the helper is installed. The helper's files are in `AEHelper/` in the repo; CI signs them
/// with a self-signed certificate (ZXPSignCmd) before the build, so no After Effects security
/// setting is changed. A local build without signing ships it unsigned (it won't load).
enum AEBridge {
    static let version = "1.0.0"

    static var base: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TaskTimer Dev/AE", isDirectory: true)
        try? FileManager.default.createDirectory(at: u.appendingPathComponent("requests"), withIntermediateDirectories: true)
        return u
    }
    static var stateURL: URL { base.appendingPathComponent("state.txt") }
    static var configURL: URL { base.appendingPathComponent("config.json") }
    private static var aliveURL: URL { base.appendingPathComponent("alive") }
    private static var requests: URL { base.appendingPathComponent("requests", isDirectory: true) }

    static var extensionFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Adobe/CEP/extensions/com.tasktimer.aehelper", isDirectory: true)
    }

    /// The extension wrote its heartbeat in the last few seconds.
    static var isAlive: Bool {
        guard AfterEffects.isRunning,
              let d = (try? FileManager.default.attributesOfItem(atPath: aliveURL.path))?[.modificationDate] as? Date
        else { return false }
        return Date().timeIntervalSince(d) < 6
    }

    /// When the extension files were last (re)written.
    static var installedAt: Date? {
        (try? FileManager.default.attributesOfItem(atPath: extensionFolder.appendingPathComponent("CSXS/manifest.xml").path))?[.modificationDate] as? Date
    }

    // MARK: Install

    /// The helper TaskTimer ships with (signed at build time, so After Effects loads it
    /// without lowering any of its security settings).
    static var bundled: URL? {
        Bundle.main.resourceURL.map { $0.appendingPathComponent("AEHelper", isDirectory: true) }
            .flatMap { FileManager.default.fileExists(atPath: $0.appendingPathComponent("CSXS/manifest.xml").path) ? $0 : nil }
    }

    /// The installed copy is signed (has its signature file).
    static var installedIsSigned: Bool {
        FileManager.default.fileExists(atPath: extensionFolder.appendingPathComponent("META-INF/signatures.xml").path)
    }

    /// Copies the bundled helper into After Effects' extensions folder when it isn't there or
    /// differs. Files are copied exactly as signed. Returns true when it was (re)installed.
    @discardableResult
    static func install() -> Bool {
        let fm = FileManager.default
        guard let src = bundled else { return false }
        func stamp(_ dir: URL) -> String {
            ["CSXS/manifest.xml", "index.html", "host.jsx", "META-INF/signatures.xml"].map {
                (try? String(contentsOf: dir.appendingPathComponent($0), encoding: .utf8)) ?? ""
            }.joined(separator: "\u{1}")
        }
        if fm.fileExists(atPath: extensionFolder.path), stamp(src) == stamp(extensionFolder) { return false }
        do {
            try fm.createDirectory(at: extensionFolder.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: extensionFolder.path) { try fm.removeItem(at: extensionFolder) }
            try fm.copyItem(at: src, to: extensionFolder)
            return true
        } catch {
            NSLog("TaskTimer: couldn't install the After Effects helper: \(error.localizedDescription)")
            return false
        }
    }

    static func writeConfig(render: Bool, naming: Bool) {
        let obj: [String: Any] = ["render": render, "naming": naming]
        if let d = try? JSONSerialization.data(withJSONObject: obj) {
            try? d.write(to: configURL, options: .atomic)
        }
    }

    // MARK: Running scripts

    /// Runs an ExtendScript through the extension. `done` is called on the main thread.
    static func run(_ js: String, timeout: TimeInterval, done: @escaping (Result<String, Error>) -> Void) {
        let id = UUID().uuidString
        let request = requests.appendingPathComponent("\(id).jsx")
        let result = requests.appendingPathComponent("\(id).result")
        do {
            // Written under a temporary name, so the extension never reads half a file.
            let tmp = requests.appendingPathComponent("\(id).tmp")
            try js.write(to: tmp, atomically: true, encoding: .utf8)
            try FileManager.default.moveItem(at: tmp, to: request)
        } catch {
            done(.failure(AfterEffects.Err("Couldn't send the script to After Effects: \(error.localizedDescription)")))
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let start = Date()
            while Date().timeIntervalSince(start) < timeout {
                if let text = try? String(contentsOf: result, encoding: .utf8) {
                    try? FileManager.default.removeItem(at: result)
                    DispatchQueue.main.async {
                        if text.hasPrefix("TT_ERROR:") {
                            done(.failure(AfterEffects.Err(String(text.dropFirst(9)))))
                        } else {
                            done(.success(text))
                        }
                    }
                    return
                }
                Thread.sleep(forTimeInterval: 0.25)
            }
            for ext in ["jsx", "run"] {
                try? FileManager.default.removeItem(at: requests.appendingPathComponent("\(id).\(ext)"))
            }
            DispatchQueue.main.async { done(.failure(AfterEffects.Err("After Effects didn't answer in time."))) }
        }
    }
}
