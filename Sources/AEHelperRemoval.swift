import Foundation

/// TaskTimer used to put a helper into After Effects (versions 1.21–1.27: a script with
/// `app.scheduleTask`, then the "TaskTimer Helper" extension) to point Render Queue outputs at
/// the task's Render folder. That was removed (Hosam's call). This takes the extension and its
/// files off the Mac; the old scheduled script goes away when After Effects quits.
enum AEHelperRemoval {
    static func run() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let paths = [
            home.appendingPathComponent("Library/Application Support/Adobe/CEP/extensions/com.tasktimer.aehelper"),
            home.appendingPathComponent("Library/Application Support/TaskTimer Dev/AE"),
            home.appendingPathComponent("Library/Application Support/TaskTimer Dev/ae-open-project.txt"),
        ]
        for p in paths where fm.fileExists(atPath: p.path) {
            try? fm.removeItem(at: p)
        }
    }
}
