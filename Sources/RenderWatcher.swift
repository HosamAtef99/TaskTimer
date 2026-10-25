import Foundation
import AppKit
import UserNotifications

/// Watches the Render folder of every task in progress. When new files appear and then stop
/// changing for a little while, the render is done: TaskTimer sends a notification that
/// asks whether to stop that task's timer.
@MainActor
final class RenderWatcher {
    static let shared = RenderWatcher()

    private struct FolderState {
        var sizes: [String: FileSig] = [:]
        var newFiles: Set<String> = []
        var lastChange: Date?
    }

    private var states: [String: FolderState] = [:]   // key: render folder path
    private var timer: Timer?

    /// Size + modified date, so a render that overwrites an existing file counts too.
    private struct FileSig: Equatable {
        var size: Int64
        var modified: Date?
    }

    /// Seconds without any change before a render counts as finished. Heavy comps can take a
    /// while per frame, so this isn't too short.
    private let quietTime: TimeInterval = 45

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scan() }
        }
    }

    private func scan() {
        guard Pref.bool(Pref.renderNotify) else { states = [:]; return }
        let store = Store.shared
        // A task is watched while it or one of its amends is in progress (an amend can be
        // in progress after the task itself was completed).
        let tasks = store.tasks
            .filter { t in
                t.parentID == nil && t.folderPath != nil
                    && (t.status.isInProgress || store.subtasks(of: t.id).contains { $0.status.isInProgress })
            }
            .prefix(40)

        var seen = Set<String>()
        for t in tasks {
            guard let f = t.folderURL,
                  let r = FolderService.folder(in: f, matching: ["render", "renders", "output"]) else { continue }
            let key = r.path
            seen.insert(key)
            let now = Self.listing(r)

            guard var st = states[key] else {
                // First look at this folder: what's already there doesn't count.
                states[key] = FolderState(sizes: now)
                continue
            }
            var changed = false
            for (path, sig) in now where st.sizes[path] != sig {
                changed = true
                // New file, or an existing one rendered again (overwritten).
                st.newFiles.insert(path)
            }
            st.newFiles = st.newFiles.filter { now[$0] != nil }   // drop temp files that vanished
            if changed { st.lastChange = Date() }
            st.sizes = now

            if !changed, !st.newFiles.isEmpty, let last = st.lastChange,
               Date().timeIntervalSince(last) >= quietTime {
                notify(task: t, folder: r, files: st.newFiles.sorted())
                st.newFiles = []
                st.lastChange = nil
            }
            states[key] = st
        }
        states = states.filter { seen.contains($0.key) }
    }

    /// Files in the render folder (two levels deep), with their sizes.
    private static func listing(_ dir: URL) -> [String: FileSig] {
        var out: [String: FileSig] = [:]
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: keys,
                                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return out }
        var count = 0
        for case let u as URL in e {
            if e.level > 2 { e.skipDescendants(); continue }
            guard let v = try? u.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            let name = u.lastPathComponent.lowercased()
            if name.hasSuffix(".tmp") || name.hasSuffix(".part") || name.hasSuffix(".crdownload") { continue }
            out[u.path] = FileSig(size: Int64(v.fileSize ?? 0), modified: v.contentModificationDate)
            count += 1
            if count > 5000 { break }
        }
        return out
    }

    private func notify(task t: TaskItem, folder: URL, files: [String]) {
        let c = UNMutableNotificationContent()
        c.title = "Render finished — \(Store.shared.displayName(t))"
        let first = (files.first as NSString?)?.lastPathComponent ?? ""
        var body = files.count == 1 ? first : "\(files.count) new files (\(first)…)"
        if t.isRunning || Store.shared.subtasks(of: t.id).contains(where: { $0.isRunning }) {
            body += "\nStop the timer?"
        }
        c.body = body
        c.sound = .default
        c.categoryIdentifier = NotificationHandler.renderCategory
        c.userInfo = ["kind": "render", "taskID": t.id.uuidString, "folder": folder.path]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
        Store.shared.flash("Render finished: \(first)")
    }
}

/// Handles the buttons on TaskTimer's notifications.
final class NotificationHandler: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationHandler()
    static let renderCategory = "RENDER_DONE"

    func install() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let stop = UNNotificationAction(identifier: "STOP", title: "Stop timer", options: [])
        let done = UNNotificationAction(identifier: "DONE", title: "Stop & Done…", options: [.foreground])
        let open = UNNotificationAction(identifier: "OPEN", title: "Show in Finder", options: [.foreground])
        let render = UNNotificationCategory(identifier: Self.renderCategory, actions: [stop, done, open],
                                            intentIdentifiers: [], options: [])
        center.setNotificationCategories([render])
    }

    // Show banners even while TaskTimer is the front app.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let kind = info["kind"] as? String ?? ""
        let taskID = (info["taskID"] as? String).flatMap { UUID(uuidString: $0) }
        let folder = info["folder"] as? String
        let action = response.actionIdentifier
        Task { @MainActor in
            let store = Store.shared
            switch (kind, action) {
            case ("render", "STOP"):
                if let id = taskID { store.stopTaskAndAmends(id) }
            case ("render", "DONE"):
                if let id = taskID {
                    let target = store.runningAmend(of: id) ?? id
                    store.stopTaskAndAmends(id)
                    store.showMainWindow()
                    store.requestDone(target)
                }
            case ("render", "OPEN"):
                if let folder { NSWorkspace.shared.open(URL(fileURLWithPath: folder)) }
            case ("weekly", _):
                store.showMainWindow()
                store.teamReportRequest = true
            default:
                store.showMainWindow()
            }
        }
        completionHandler()
    }
}
