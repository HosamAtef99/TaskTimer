import Foundation
import AppKit

/// What TaskTimer does inside After Effects, through its helper extension (`AEBridge`):
///   • Render folder (`Pref.aeRenderToTask`): in a task's project (the .aep in `Task/<AE folder>/`
///     or `Task/`, with a Render / Renders / Output folder in `Task/`), a comp newly added to the
///     Render Queue gets its output set to the task's Render folder; when the project is first
///     opened, queued items pointing outside the task folder are moved there too.
///   • Names (`Pref.aeRenderNaming`): those outputs are named `<Task>_v01`, `_v02`…
/// Changing an output by hand afterwards is kept. Nothing else in the project is touched.
/// (Older versions put a script into After Effects with DoScript + `app.scheduleTask`; that
/// made After Effects show "Cannot run a script while a modal dialog is waiting" whenever one
/// of its windows was open. The extension doesn't.)
@MainActor
enum AERenderHelper {
    private static var observer: NSObjectProtocol?


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

/// The status line in Settings → General: is TaskTimer's helper running in After Effects.
/// Only looks at the helper's heartbeat file — nothing is sent to After Effects.
@MainActor
enum AETimerWatcher {
    final class Status: ObservableObject {
        static let shared = Status()
        @Published var text = ""
        @Published var problem = false
    }

    private static var timer: Timer?

    static func start() {
        guard timer == nil else { return }
        update()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
            Task { @MainActor in update() }
        }
    }

    private static func say(_ text: String, problem: Bool = false) {
        let s = Status.shared
        if s.text != text { s.text = text }
        if s.problem != problem { s.problem = problem }
    }

    static func update() {
        guard AfterEffects.isRunning else { say("After Effects isn't open."); return }
        if AEBridge.isAlive { say("Connected to After Effects ✓"); return }
        if AEBridge.bundled != nil && !AEBridge.installedIsSigned {
            say("This copy of TaskTimer has an unsigned After Effects helper (built without signing), so After Effects won't load it. Use a TaskTimer from GitHub Releases.", problem: true)
            return
        }
        let launched = AfterEffects.running?.launchDate ?? .distantPast
        if let installed = AEBridge.installedAt, launched < installed {
            say("Quit and reopen After Effects once, so TaskTimer's helper loads inside it.", problem: true)
        } else {
            say("TaskTimer's helper didn't start by itself. In After Effects open Window → Extensions → TaskTimer Helper once and dock that small panel anywhere (After Effects reopens it next time). If “TaskTimer Helper” isn't in that menu, or the panel shows an error, send a screenshot.", problem: true)
        }
    }
}
