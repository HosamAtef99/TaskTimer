import Foundation
import AppKit
import CoreGraphics

/// Settings → Folders → "Send Render Queue items to the task's Render folder automatically"
/// (Hosam's call, 1.30). While After Effects is the app in front, every 10 s TaskTimer asks it
/// (one short DoScript) whether the open project is in the folder of a task that isn't
/// Completed. A minute after that project was first seen open, queued Render Queue items go to
/// the task's Render folder as `<Task>_v01`… — the same as the Set Render Outputs button.
///
/// To stay out of the way: nothing is sent while After Effects is in the background, in its
/// first minute after starting, while one of its menus or dialogs is up, while you're clicking
/// or typing (until you've paused 2 s), or while the previous check hasn't answered (e.g. it's
/// rendering). Errors are never shown.
@MainActor
final class AutoRenderOutputs {
    static let shared = AutoRenderOutputs()

    private var timer: Timer?
    private var busy = false
    /// Open project path → when TaskTimer first saw it open.
    private var seen: (path: String, at: Date)?
    private(set) var lastNote = ""

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
            Task { @MainActor in AutoRenderOutputs.shared.tick() }
        }
    }

    private func tick() {
        guard Pref.bool(Pref.autoRenderOutputs), !busy else { return }
        guard let ae = AfterEffects.running else { seen = nil; return }
        guard ae.isActive else { return }
        if let launched = ae.launchDate, Date().timeIntervalSince(launched) < 60 { return }
        // You're in the middle of something: wait for a 2-second pause.
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        guard idle >= 2 else { return }
        guard !hasDialogOrMenu(pid: ae.processIdentifier) else { lastNote = "waiting: After Effects has a window open"; return }

        // Tasks and amends that aren't Completed (an amend uses its task's folder).
        let store = Store.shared
        var folders: [URL] = []
        for t in store.tasks where t.status != .complete {
            guard let f = (t.parentID == nil ? t : store.parent(of: t))?.folderURL,
                  !folders.contains(f) else { continue }
            folders.append(f)
        }
        let targets = folders.compactMap { f -> [String: String]? in
            guard let render = FolderService.folder(in: f, matching: ["render", "renders", "output"]) else { return nil }
            return AEProjectTools.renderTarget(taskFolder: f, render: render)
        }
        guard !targets.isEmpty else { return }

        // Only change things once the project has been open for a minute.
        let ready = seen.flatMap { Date().timeIntervalSince($0.at) >= 60 ? $0.path : nil }
        let script = AEProjectTools.renderScript(targets, onlyIf: ready ?? "\u{0}")
        busy = true
        AfterEffects.doScript(script, timeout: 8) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.busy = false
                guard case .success(let text) = result else { return }
                if text.hasPrefix("seen ") {
                    let path = String(text.dropFirst(5))
                    if self.seen?.path != path { self.seen = (path, Date()) }
                    self.lastNote = "waiting a minute after the project opened"
                } else if text == "notopen" {
                    self.seen = nil
                    self.lastNote = "the open project isn't a task's"
                } else if text.hasPrefix("ok ") {
                    let parts = text.split(separator: " ")
                    let changed = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
                    self.lastNote = "checked"
                    if changed > 0 {
                        Store.shared.flash("\(changed) render output\(changed == 1 ? "" : "s") → the task's Render folder")
                    }
                }
            }
        }
    }

    /// Whether After Effects shows a menu, a dialog or another window above its normal ones.
    /// (A DoScript then makes After Effects say "Cannot run a script while a modal dialog is
    /// waiting".) Window levels need no permission to read.
    private func hasDialogOrMenu(pid: pid_t) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        return list.contains { w in
            (w[kCGWindowOwnerPID as String] as? Int32) == pid && (w[kCGWindowLayer as String] as? Int ?? 0) >= 8
        }
    }
}
