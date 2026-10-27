import Foundation
import AppKit

/// The small helper TaskTimer puts into the running After Effects (one DoScript, then it runs
/// inside After Effects with `app.scheduleTask` every 2 seconds, as `$.global.TaskTimerRQ`).
///
/// It does three things, each switched on in Settings → General:
///   • Render folder (`Pref.aeRenderToTask`): in a task's project (the .aep in `Task/<AE folder>/`
///     or `Task/`, with a Render / Renders / Output folder in `Task/`), a comp newly added to the
///     Render Queue gets its output set to the task's Render folder. When the project is first
///     opened, queued items pointing outside the task folder are moved there too.
///   • Names (`Pref.aeRenderNaming`): those outputs are named `<Task>_v01`, `_v02`… (next free
///     number in the Render folder and the queue), so a render never overwrites an older one.
///   • Open project (`Pref.aeAutoTimer`): writes the open project's path to `stateURL`
///     (when it changes, and every 30 s); `AETimerWatcher` starts and pauses timers from it.
///     Writing a file needs After Effects' "Allow Scripts to Write Files and Access Network".
/// Changing an output by hand afterwards is kept. Nothing else in the project is touched.
/// The helper lives until After Effects quits; TaskTimer adds it again on the next launch.
@MainActor
enum AERenderHelper {
    private static var installedPID: pid_t?
    private static var attempts: [pid_t: Int] = [:]
    private static var observer: NSObjectProtocol?

    /// After Effects' "Allow Scripts to Write Files and Access Network": nil = not known yet.
    static var canWriteFiles: Bool?

    /// The helper is in the After Effects that's running now.
    static var connected: Bool {
        guard let pid = AfterEffects.running?.processIdentifier else { return false }
        return installedPID == pid
    }

    static var enabled: Bool {
        Pref.bool(Pref.aeRenderToTask) || Pref.bool(Pref.aeAutoTimer)
    }

    static var stateURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TaskTimer Dev", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("ae-open-project.txt")
    }

    private static var config: String {
        func js(_ s: String) -> String {
            let data = try? JSONSerialization.data(withJSONObject: [s], options: [])
            let arr = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
            return String(arr.dropFirst().dropLast())
        }
        let render = Pref.bool(Pref.aeRenderToTask)
        let naming = render && Pref.bool(Pref.aeRenderNaming)
        let state = Pref.bool(Pref.aeAutoTimer) ? js(stateURL.path) : "\"\""
        return "{render: \(render), naming: \(naming), state: \(state)}"
    }

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

    /// Puts the helper into the running After Effects (once per launch of After Effects), or
    /// updates its settings when `force` is set.
    static func ensure(force: Bool = false) {
        guard let app = AfterEffects.running else { return }
        let pid = app.processIdentifier
        if !enabled {
            if installedPID == pid { send("if ($.global.TaskTimerRQ) { $.global.TaskTimerRQ.off = true; } 'ok';") }
            installedPID = nil
            return
        }
        if installedPID == pid && !force { return }
        // At most 2 tries per launch on its own: a try while After Effects shows a window of
        // its own makes it show an error.
        let n = attempts[pid, default: 0]
        guard n < 2 || force else { return }
        attempts[pid] = n + 1

        AfterEffects.doScript(script.replacingOccurrences(of: "__CFG__", with: config), timeout: 20) { result in
            Task { @MainActor in
                switch result {
                case .success(let text):
                    installedPID = pid
                    // "ok added 1" / "ok already 0": the last number is the write-files setting.
                    if let last = text.split(separator: " ").last, let v = Int(last), v >= 0 {
                        canWriteFiles = v == 1
                    }
                case .failure(let e):
                    NSLog("TaskTimer: After Effects helper not added: \(e.localizedDescription)")
                    if (attempts[pid] ?? 0) < 2 {
                        try? await Task.sleep(nanoseconds: 60_000_000_000)
                        ensure()
                    }
                }
            }
        }
    }

    /// Settings changed: tell the helper (or switch it off).
    static func settingsChanged() { ensure(force: true) }

    private static func send(_ js: String) {
        AfterEffects.doScript(js, timeout: 20) { _ in }
    }

    // ExtendScript that runs inside After Effects. __CFG__ is replaced with the settings.
    private static let script = #"""
    (function () {
      var V = 2;
      var CFG = __CFG__;
      function canWrite() {
        try { return app.preferences.getPrefAsLong("Main Pref Section", "Pref_SCRIPTING_FILE_NETWORK_SECURITY"); }
        catch (e) { return -1; }
      }
      var old = $.global.TaskTimerRQ;
      if (old && old.version >= V) { old.cfg = CFG; old.off = false; old.lastState = null; return "ok already " + canWrite(); }
      var T = { version: V, off: false, cfg: CFG, proj: null, count: 0, lastState: null, lastWrite: 0 };

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
      function safe(s) { return s.replace(/[\/\\:*?"<>|]/g, "-"); }

      // Next free _vNN for this task: in the Render folder and in the queue.
      function nextVersion(info, base) {
        var max = 0;
        function look(name) {
          if (name.indexOf(base) !== 0) return;
          var m = name.substr(base.length).match(/^(\d+)/);
          if (m) max = Math.max(max, parseInt(m[1], 10));
        }
        var files = info.render.getFiles();
        for (var i = 0; i < files.length; i++) look(decodeURI(files[i].name));
        var rq = app.project.renderQueue;
        for (var r = 1; r <= rq.numItems; r++) {
          var it = rq.item(r);
          for (var m = 1; m <= it.numOutputModules; m++) {
            var f = it.outputModule(m).file;
            if (f) look(decodeURI(f.name));
          }
        }
        var n = max + 1;
        return (n < 10 ? "0" : "") + n;
      }

      function place(om, cur, info) {
        var name = decodeURI(cur.name);
        if (T.cfg.naming) {
          var base = safe(decodeURI(info.root.name)) + "_v";
          if (name.indexOf(base) !== 0) {
            var dot = name.lastIndexOf(".");
            var ext = dot > 0 ? name.substr(dot) : "";
            var seq = name.match(/_?\[#+\]/);
            name = base + nextVersion(info, base) + (seq ? "_" + seq[0].replace(/^_/, "") : "") + ext;
          }
        }
        om.file = new File(info.render.fsName + "/" + name);
      }

      T.render = function () {
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
            if (!cur) continue;
            if (fresh) {
              // At first look, only fix outputs that point outside the task folder.
              if (inside(cur, info.root)) continue;
              place(om, cur, info);
            } else if (!inside(cur, info.render) || T.cfg.naming) {
              place(om, cur, info);
            }
          }
        }
        T.count = n;
      };

      T.writeState = function () {
        if (!T.cfg.state) return;
        var f = app.project ? app.project.file : null;
        var s = f ? f.fsName : "";
        var now = new Date().getTime();
        if (s === T.lastState && now - T.lastWrite < 30000) return;
        var out = new File(T.cfg.state);
        out.encoding = "UTF-8";
        if (out.open("w")) {
          out.write(s + "\n" + now);
          out.close();
          T.lastState = s;
          T.lastWrite = now;
        }
      };

      T.tick = function () {
        if (T.off) return;
        try { T.writeState(); } catch (e) { }
        if (!T.cfg.render) return;
        try { T.render(); } catch (e) { }
      };

      $.global.TaskTimerRQ = T;
      // An older helper already ticks this name every 2 s; only schedule once.
      if (!old) app.scheduleTask("if ($.global.TaskTimerRQ) $.global.TaskTimerRQ.tick();", 2000, true);
      return "ok added " + canWrite();
    })();
    """#
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
        if !AERenderHelper.connected {
            say("TaskTimer isn't connected to After Effects yet (it connects about 40 s after After Effects opens) — press Connect now.", problem: true)
            return nil
        }
        if AERenderHelper.canWriteFiles == false {
            say("After Effects doesn't let scripts write files. Turn on Settings → Scripting & Expressions → “Allow Scripts to Write Files and Access Network” in After Effects, then press Connect now.", problem: true)
            return nil
        }
        guard let text = try? String(contentsOf: AERenderHelper.stateURL, encoding: .utf8) else {
            say("No word from After Effects yet. Check “Allow Scripts to Write Files and Access Network” is on in After Effects (Settings → Scripting & Expressions), then press Connect now.", problem: true)
            return nil
        }
        let lines = text.components(separatedBy: .newlines)
        guard lines.count >= 2, let ms = Double(lines[1].trimmingCharacters(in: .whitespaces)) else { return nil }
        // The helper writes at least every 30 s; older means it isn't running.
        if Date().timeIntervalSince1970 - ms / 1000 > 90 {
            say("After Effects stopped answering TaskTimer — press Connect now.", problem: true)
            return nil
        }
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
