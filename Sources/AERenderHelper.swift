import Foundation
import AppKit

/// Makes After Effects render a task's project into that task's Render folder.
///
/// TaskTimer puts a small helper into the running After Effects (one DoScript, using
/// `app.scheduleTask`). Every 2 seconds, inside After Effects, it looks at the open project:
/// when the .aep sits in a TaskTimer task folder (`Task/01 - AE/Task.aep`, or the .aep right in
/// `Task/`) that has a Render folder, then
///   • a comp newly added to the Render Queue gets its output set to that Render folder
///     (same file name After Effects chose), and
///   • when the project is first opened, queued items whose output points outside the task
///     folder (e.g. left over from the template) are pointed to the Render folder too.
/// Changing an item's output by hand afterwards is respected. Nothing else in the project is
/// touched. The helper lives until After Effects quits; TaskTimer adds it again on the next
/// launch.
@MainActor
enum AERenderHelper {
    private static var installedPID: pid_t?
    private static var attempts: [pid_t: Int] = [:]
    private static var observer: NSObjectProtocol?

    static var enabled: Bool { Pref.bool(Pref.aeRenderToTask) }

    /// Called once at app start.
    static func start() {
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  (app.bundleIdentifier ?? "").hasPrefix("com.adobe.AfterEffects") else { return }
            // Give After Effects time to finish starting (plugins, home screen).
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 40_000_000_000)
                ensure()
            }
        }
        // After Effects already open when TaskTimer starts.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            ensure()
        }
    }

    /// Puts the helper into the running After Effects, once per launch of After Effects.
    static func ensure(force: Bool = false) {
        guard enabled, let app = AfterEffects.running, let id = app.bundleIdentifier else { return }
        let pid = app.processIdentifier
        if installedPID == pid && !force { return }
        // At most 2 tries per launch: a try while After Effects shows a window of its own
        // makes it show an error.
        let n = attempts[pid, default: 0]
        guard n < 2 || force else { return }
        attempts[pid] = n + 1

        let escaped = script
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        tell application id "\(id)"
            with timeout of 20 seconds
                DoScript "\(escaped)"
            end timeout
        end tell
        """
        DispatchQueue.global(qos: .utility).async {
            var err: NSDictionary?
            _ = NSAppleScript(source: source)?.executeAndReturnError(&err)
            let ok = err == nil
            let detail = err.map { "\($0)" } ?? ""
            Task { @MainActor in
                if ok {
                    installedPID = pid
                } else {
                    NSLog("TaskTimer: After Effects render helper not added: \(detail)")
                    // Try once more a bit later (After Effects may have been busy).
                    if (attempts[pid] ?? 0) < 2 {
                        try? await Task.sleep(nanoseconds: 60_000_000_000)
                        ensure()
                    }
                }
            }
        }
    }

    /// Stops the helper (when the setting is turned off).
    static func stop() {
        guard let app = AfterEffects.running, let id = app.bundleIdentifier, installedPID == app.processIdentifier else { return }
        installedPID = nil
        let source = """
        tell application id "\(id)"
            with timeout of 20 seconds
                DoScript "if ($.global.TaskTimerRQ) { $.global.TaskTimerRQ.off = true; } 'ok';"
            end timeout
        end tell
        """
        DispatchQueue.global(qos: .utility).async {
            var err: NSDictionary?
            _ = NSAppleScript(source: source)?.executeAndReturnError(&err)
        }
    }

    // ExtendScript that runs inside After Effects.
    private static let script = #"""
    (function () {
      var V = 1;
      var T = $.global.TaskTimerRQ;
      if (T && T.version >= V) { T.off = false; return "ok already"; }
      T = { version: V, off: false, proj: null, count: 0 };

      function words(n) { return decodeURI(n).toLowerCase().split(/[^a-z0-9]+/); }
      function has(n, list) {
        var w = words(n);
        for (var i = 0; i < w.length; i++) for (var j = 0; j < list.length; j++) if (w[i] === list[j]) return true;
        return false;
      }
      // The task folder and its Render folder for the open project, or null.
      function taskFolders() {
        var f = app.project ? app.project.file : null;
        if (!f) return null;
        var root = f.parent;
        if (has(root.name, ["ae"]) && root.parent) root = root.parent;
        var subs = root.getFiles(function (x) { return x instanceof Folder; });
        var keys = ["render", "renders", "output"];
        for (var k = 0; k < keys.length; k++)
          for (var s = 0; s < subs.length; s++)
            if (has(subs[s].name, [keys[k]])) return { root: root, render: subs[s] };
        return null;
      }
      function inside(file, folder) {
        return file && file.fsName.indexOf(folder.fsName + "/") === 0;
      }

      T.tick = function () {
        if (T.off) return;
        try {
          var info = taskFolders();
          if (!info) { T.proj = null; T.count = 0; return; }
          var rq = app.project.renderQueue;
          var n = rq.numItems;
          var fresh = T.proj !== info.root.fsName;
          if (fresh) { T.proj = info.root.fsName; T.count = 0; }
          for (var i = 1; i <= n; i++) {
            var isNew = !fresh && i > T.count;
            if (!fresh && !isNew) continue;
            var it = rq.item(i);
            if (it.status !== RQItemStatus.QUEUED && it.status !== RQItemStatus.UNQUEUED) continue;
            for (var m = 1; m <= it.numOutputModules; m++) {
              var om = it.outputModule(m);
              var cur = om.file;
              if (!cur || inside(cur, info.render)) continue;
              // At first look, keep outputs the person already put inside the task folder.
              if (fresh && inside(cur, info.root)) continue;
              om.file = new File(info.render.fsName + "/" + decodeURI(cur.name));
            }
          }
          T.count = n;
        } catch (e) { }
      };

      $.global.TaskTimerRQ = T;
      app.scheduleTask("if ($.global.TaskTimerRQ) $.global.TaskTimerRQ.tick();", 2000, true);
      return "ok added";
    })();
    """#
}
