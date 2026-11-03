import Foundation
import AppKit

/// For trying the admin, leader and member views at the same time on one Mac (Hosam's call,
/// temporary): Settings → General → Test Copies makes "TaskTimer Test 2" / "Test 3" in
/// ~/Applications — copies of this app with their own bundle ID, so each has its own settings,
/// sign-in and data folder ("TaskTimer Dev Test 2"…). Copies don't update themselves and don't
/// install the Chrome extension; they're refreshed from the main app each time they're opened.
enum TestCopies {
    static let mainBundleID = "com.hosam.tasktimer.dev"

    /// 2 or 3 in a test copy, nil in the real app.
    static var number: Int? {
        guard let id = Bundle.main.bundleIdentifier, id.hasPrefix(mainBundleID + ".test") else { return nil }
        return Int(id.dropFirst((mainBundleID + ".test").count))
    }
    static var isCopy: Bool { number != nil }

    /// "TaskTimer Dev", or "TaskTimer Test 2" in a copy.
    static var appTitle: String { number.map { "TaskTimer Test \($0)" } ?? "TaskTimer Dev" }

    /// Application Support folder for this app's sign-in and data.
    static var supportDir: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(number.map { "TaskTimer Dev Test \($0)" } ?? "TaskTimer Dev", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func copyURL(_ n: Int) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/TaskTimer Test \(n).app", isDirectory: true)
    }

    /// Makes (or refreshes) copy `n` and opens it.
    static func open(_ n: Int) {
        let dest = copyURL(n)
        let fm = FileManager.default
        let src = Bundle.main.bundleURL
        DispatchQueue.global(qos: .userInitiated).async {
            var error: String?
            do {
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                // Quit the copy if it's running, so it can be replaced.
                let id = "\(mainBundleID).test\(n)"
                for app in NSRunningApplication.runningApplications(withBundleIdentifier: id) { app.terminate() }
                for _ in 0..<30 where !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty {
                    Thread.sleep(forTimeInterval: 0.2)
                }
                if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                try fm.copyItem(at: src, to: dest)
                let plist = dest.appendingPathComponent("Contents/Info.plist")
                run("/usr/libexec/PlistBuddy", ["-c", "Set :CFBundleIdentifier \(id)", plist.path])
                run("/usr/libexec/PlistBuddy", ["-c", "Set :CFBundleName 'TaskTimer Test \(n)'", plist.path])
                run("/usr/libexec/PlistBuddy", ["-c", "Delete :CFBundleDisplayName", plist.path])
                run("/usr/bin/xattr", ["-cr", dest.path])
                if run("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", dest.path]) != 0 {
                    error = "Couldn't sign the copy."
                }
            } catch {
                DispatchQueue.main.async { alert("Couldn't make Test Copy \(n)", error.localizedDescription) }
                return
            }
            DispatchQueue.main.async {
                if let error { alert("Couldn't make Test Copy \(n)", error); return }
                let cfg = NSWorkspace.OpenConfiguration()
                cfg.createsNewApplicationInstance = true
                NSWorkspace.shared.openApplication(at: dest, configuration: cfg) { _, err in
                    if let err { DispatchQueue.main.async { alert("Couldn't open Test Copy \(n)", err.localizedDescription) } }
                }
            }
        }
    }

    @discardableResult
    private static func run(_ path: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus } catch { return -1 }
    }

    private static func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }
}
