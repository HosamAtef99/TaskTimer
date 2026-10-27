import Foundation
import AppKit

/// What TaskTimer does inside After Effects, through its helper extension (`AEBridge`):
///   • Render folder (`Pref.aeRenderToTask`): in a task's project (the .aep in `Task/<AE folder>/`
///     or `Task/`, with a Render / Renders / Output folder in `Task/`), a comp newly added to the
///     Render Queue gets its output set to the task's Render folder; when the project is first
///     opened, queued items pointing outside the task folder are moved there too.
///   • Names (`Pref.aeRenderNaming`): those outputs are named `<Task>_v01`, `_v02`…
///   • Open project (`Pref.aeAutoTimer`): `AETimerWatcher` starts and pauses timers from the
///     open project's path the helper writes.
/// Changing an output by hand afterwards is kept. Nothing else in the project is touched.
/// (Older versions put a script into After Effects with DoScript + `app.scheduleTask`; that
/// made After Effects show "Cannot run a script while a modal dialog is waiting" whenever one
/// of its windows was open. The extension doesn't.)
@MainActor
enum AERenderHelper {
    private static var observer: NSObjectProtocol?

    static var stateURL: URL { AEBridge.stateURL }

    /// The helper is running inside After Effects now.
    static var connected: Bool { AEBridge.isAlive }

    static func start() {
        ensure()
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  (app.bundleIdentifier ?? "").hasPrefix("com.adobe.AfterEffects") else { return }
            Task { @MainActor in ensure() }
        }
    }

    /// Installs / updates the helper extension and its settings. No script is sent to
    /// After Effects.
    static func ensure(force: Bool = false) {
        AEBridge.install()
        settingsChanged()
    }

    static func settingsChanged() {
        let render = Pref.bool(Pref.aeRenderToTask)
        AEBridge.writeConfig(render: render, naming: render && Pref.bool(Pref.aeRenderNaming))
    }
}

/// Starts the task's timer when its After Effects project is opened, and pauses it when the
/// project is closed or another one is opened (`Pref.aeAutoTimer`). Reads what the helper in
/// After Effects writes; only acts when the open project changes, so pausing by hand while
/// the project is open is kept.
@MainActor
enum AETimerWatcher {
    private static var timer: Timer?
    private static var lastSeen: String?      // path seen on the last check
    private static var acted: String?         // path last acted on
    private static var autoStarted: UUID?     // the task this started

    /// What the watcher sees right now, in words (Settings → General).
    final class Status: ObservableObject {
        static let shared = Status()
        @Published var text = ""
        @Published var problem = false
    }

    private static func say(_ text: String, problem: Bool = false) {
        let s = Status.shared
        if s.text != text { s.text = text }
        if s.problem != problem { s.problem = problem }
    }

    static func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            Task { @MainActor in check() }
        }
    }

    /// The open project's path ("" = none / After Effects closed), or nil when unknown.
    private static func openProject() -> String? {
        guard AfterEffects.isRunning else {
            say("After Effects isn't open.")
            return ""
        }
        if !AERenderHelper.connected && AEBridge.bundled != nil && !AEBridge.installedIsSigned {
            say("This copy of TaskTimer has an unsigned After Effects helper (built without signing), so After Effects won't load it. Use a TaskTimer from GitHub Releases.", problem: true)
            return nil
        }
        if !AERenderHelper.connected {
            let launched = AfterEffects.running?.launchDate ?? .distantPast
            if let installed = AEBridge.installedAt, launched < installed {
                say("Quit and reopen After Effects once, so TaskTimer's helper loads inside it.", problem: true)
            } else {
                say("TaskTimer's helper didn't start by itself. In After Effects open Window → Extensions → TaskTimer Helper once and dock that small panel anywhere (After Effects reopens it next time). If “TaskTimer Helper” isn't in that menu, or the panel shows an error, send a screenshot.", problem: true)
            }
            return nil
        }
        guard let text = try? String(contentsOf: AERenderHelper.stateURL, encoding: .utf8) else {
            say("Connected to After Effects — waiting for its first answer…")
            return nil
        }
        let lines = text.components(separatedBy: .newlines)
        guard lines.count >= 2 else { return nil }
        return lines[0]
    }

    /// Same folder whatever the spelling: symlinks resolved, Unicode normalized, case ignored.
    private static func normalized(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
            .precomposedStringWithCanonicalMapping.lowercased()
    }

    private static func check() {
        guard Pref.bool(Pref.aeAutoTimer) else { say("Off."); lastSeen = nil; return }
        guard let path = openProject() else { lastSeen = nil; return }
        let task = taskFor(path)
        if path.isEmpty {
            if AfterEffects.isRunning { say("No project open in After Effects.") }
        } else if let task {
            say("Open in After Effects: \((path as NSString).lastPathComponent) → “\(task.name)”")
        } else {
            say("Open in After Effects: \((path as NSString).lastPathComponent) — not in any task's folder.")
        }

        // Same value twice in a row (5 s apart), so a Save As doesn't flicker the timer.
        defer { lastSeen = path }
        guard path == lastSeen, path != acted else { return }
        acted = path
        let store = Store.shared

        // Leaving a task's project: pause that task's timer (whoever started it), unless the
        // project now open is the same task's.
        let leaving = autoStarted ?? store.running?.id
        if let id = leaving, let t = store.task(id), t.isRunning {
            let top = t.parentID ?? t.id
            if task?.id != top {
                store.pause(id)
                store.flash("Paused “\(store.displayName(t))” — its After Effects project isn't open any more")
            }
        }
        autoStarted = nil
        guard let task else { return }

        // An amend in progress gets the time; a completed task with none isn't reopened.
        let amend = store.subtasks(of: task.id).last { $0.status.isInProgress || $0.status == .incoming }
        // Already timing this task (or one of its amends): leave it.
        if store.tasks.contains(where: { $0.isRunning && ($0.id == task.id || $0.parentID == task.id) }) { return }
        let target: TaskItem
        if task.status == .complete {
            guard let a = amend else {
                store.flash("“\(task.name)” is completed — add an amend to time this round")
                return
            }
            target = a
        } else {
            target = amend.flatMap { $0.status.isInProgress ? $0 : nil } ?? task
        }
        store.start(target.id)
        autoStarted = target.id
        store.flash("Timer started for “\(store.displayName(target))” (After Effects)")
    }

    /// The top-level task whose folder holds this project file.
    private static func taskFor(_ path: String) -> TaskItem? {
        guard !path.isEmpty else { return nil }
        let p = normalized(path)
        return Store.shared.tasks
            .filter { $0.parentID == nil }
            .compactMap { t -> (TaskItem, Int)? in
                guard let raw = t.folderPath else { return nil }
                let f = normalized(raw)
                guard p.hasPrefix(f + "/") else { return nil }
                return (t, f.count)
            }
            .max { $0.1 < $1.1 }?.0
    }
}
