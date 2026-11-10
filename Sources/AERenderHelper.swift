import Foundation
import AppKit
import CoreGraphics

/// Settings → Folders → "Render Queue items go to the task's Render folder automatically" (on by
/// default; Hosam's call, 1.32 — the way the very first version, 1.21, did it).
///
/// Mongez puts a small helper into After Effects once each time After Effects starts: one script,
/// sent together with the first thing you ask After Effects to do, or on its own when After
/// Effects has no dialog or menu open and you've paused for a moment. The helper lives inside
/// After Effects (`app.scheduleTask`, every 2 s) and only looks at the open project's Render Queue:
///   • the project is a Mongez task's when a folder above it (up to 3 levels) has the task's
///     `.tasktimer.json`; its Render folder is that task folder's folder named "Render"…;
///   • an item added to the Render Queue gets the task's Render folder and the next free
///     `<Task folder>_v01`, `_v02`… name (the same as the Set Render Outputs button);
///   • when a task's project is opened, queued items that point outside the task folder (or
///     nowhere yet) are pointed to the Render folder too;
///   • an output changed by hand afterwards is left alone. Projects of other folders are never
///     touched.
/// Mongez itself doesn't talk to After Effects on a timer: it only checks (locally) whether After
/// Effects is running and has the helper. Since the helper runs inside After Effects, it can't
/// collide with an import or another script.
enum AERenderHelper {
    /// Bump when the script below changes: a running After Effects then takes the new one.
    static let version = 2

    private static var installedPID: pid_t?
    private static var attempts: [pid_t: Int] = [:]
    private static var lastTry: Date?
    private static var sending = false
    private static var timer: Timer?

    static var enabled: Bool { Pref.bool(Pref.autoRenderOutputs) && !TestCopies.isCopy }

    /// Called once at app start (main thread).
    static func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { _ in
            DispatchQueue.main.async { tick() }
        }
    }

    /// The helper's script when this After Effects doesn't have it yet, otherwise "". Sent in
    /// front of the next script (`AfterEffects.doScript`).
    static func prelude(pid: pid_t) -> String {
        guard enabled, installedPID != pid else { return "" }
        return script + "\n"
    }

    /// The script with the helper in front ran in this After Effects.
    static func installed(pid: pid_t) {
        DispatchQueue.main.async {
            if enabled { installedPID = pid }
        }
    }

    /// Looks (locally, without asking After Effects anything) whether a running After Effects
    /// still needs the helper, and sends it at a quiet moment.
    private static func tick() {
        guard enabled, !sending, let ae = AfterEffects.running else { return }
        let pid = ae.processIdentifier
        if installedPID == pid { return }
        // Let After Effects finish starting (plugins, the Home screen).
        if let launched = ae.launchDate, Date().timeIntervalSince(launched) < 25 { return }
        if let last = lastTry, Date().timeIntervalSince(last) < 30 { return }
        guard attempts[pid, default: 0] < 3 else { return }
        // Not while you're clicking or typing, and never while After Effects shows a dialog or a menu
        // (a script then makes it say "Cannot run a script while a modal dialog is waiting").
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        guard idle >= 1.5, !AfterEffects.hasOpenDialog(pid: pid) else { return }

        sending = true
        lastTry = Date()
        attempts[pid, default: 0] += 1
        AfterEffects.doScript("'mongez helper';", timeout: 20, waitLimit: 3, quiet: true) { _ in
            sending = false
        }
    }

    /// Settings: turned off. The helper in After Effects stops looking (until it's turned on again).
    static func stop() {
        guard let ae = AfterEffects.running, installedPID == ae.processIdentifier else { return }
        installedPID = nil
        AfterEffects.doScript("if ($.global.MongezRQ) { $.global.MongezRQ.off = true; } 'ok';",
                              timeout: 20, waitLimit: 30, quiet: true) { _ in }
    }

    // MARK: - The helper (ExtendScript, runs inside After Effects)

    private static let script = #"""
    (function () {
      try {
        var V = \#(version), G = $.global;
        if (G.TaskTimerRQ) G.TaskTimerRQ.off = true;       // the helper of TaskTimer 1.21–1.27
        var H = G.MongezRQ;
        if (H && H.version === V) { H.off = false; return; }
        if (H) { H.off = true; try { app.cancelTask(H.task); } catch (e0) {} }
        H = { version: V, off: false, path: null, info: null, count: 0, looked: 0, task: 0 };

        function words(n) { return decodeURI(n).toLowerCase().split(/[^a-z0-9]+/); }
        function has(n, key) {
          var w = words(n);
          for (var i = 0; i < w.length; i++) if (w[i] === key) return true;
          return false;
        }
        function renderIn(dir) {
          var subs = dir.getFiles(function (x) { return x instanceof Folder; });
          subs.sort(function (a, b) { return a.name < b.name ? -1 : (a.name > b.name ? 1 : 0); });
          var keys = ["render", "renders", "output"];
          for (var k = 0; k < keys.length; k++)
            for (var s = 0; s < subs.length; s++) if (has(subs[s].name, keys[k])) return subs[s];
          return null;
        }
        // The Mongez task of a project: a folder above it (up to 3 levels) with the task's
        // .tasktimer.json, and that folder's Render folder.
        function taskOf(file) {
          var dir = file.parent;
          for (var up = 0; up < 3 && dir; up++) {
            if (new File(dir.fsName + "/.tasktimer.json").exists) {
              var r = renderIn(dir);
              if (!r) return null;
              var base = decodeURI(dir.name).replace(/^\s+|\s+$/g, "").replace(/[\/:\\]/g, "-") + "_v";
              return { task: dir, render: r, base: base };
            }
            dir = dir.parent;
          }
          return null;
        }
        function inside(f, folder) { return f && f.fsName.indexOf(folder.fsName + "/") === 0; }
        function nextNumber(info, rq) {
          var max = 0;
          function look(name) {
            if (name.indexOf(info.base) !== 0) return;
            var m = name.substr(info.base.length).match(/^(\d+)/);
            if (m) max = Math.max(max, parseInt(m[1], 10));
          }
          var files = info.render.getFiles();
          for (var i = 0; i < files.length; i++) look(decodeURI(files[i].name));
          for (var r = 1; r <= rq.numItems; r++)
            for (var m = 1; m <= rq.item(r).numOutputModules; m++) {
              var f = rq.item(r).outputModule(m).file;
              if (f) look(decodeURI(f.name));
            }
          return max + 1;
        }
        // The file ending for an output that has no file yet, from its format.
        function endingOf(om) {
          try {
            var f = String(om.getSettings(GetSettingsFormat.STRING)["Format"]).toLowerCase();
            if (f.indexOf("quicktime") >= 0) return ".mov";
            if (f.indexOf("264") >= 0 || f.indexOf("mp4") >= 0) return ".mp4";
            if (f.indexOf("png") >= 0) return "_[#####].png";
            if (f.indexOf("jpeg") >= 0 || f.indexOf("jpg") >= 0) return "_[#####].jpg";
            if (f.indexOf("tiff") >= 0) return "_[#####].tif";
            if (f.indexOf("targa") >= 0) return "_[#####].tga";
            if (f.indexOf("exr") >= 0) return "_[#####].exr";
            if (f.indexOf("photoshop") >= 0) return "_[#####].psd";
            if (f.indexOf("wav") >= 0) return ".wav";
            if (f.indexOf("aiff") >= 0) return ".aif";
            if (f.indexOf("mp3") >= 0) return ".mp3";
            if (f.indexOf("avi") >= 0) return ".avi";
          } catch (e) {}
          return "";
        }
        function point(om, info, n) {
          var cur = om.file, tail;
          if (cur) {
            var name = decodeURI(cur.name), dot = name.lastIndexOf(".");
            var ext = dot > 0 ? name.substr(dot) : "";
            var seq = name.match(/_?\[#+\]/);
            tail = (seq ? "_" + seq[0].replace(/^_/, "") : "") + ext;
          } else {
            tail = endingOf(om);
          }
          om.file = new File(info.render.fsName + "/" + info.base + (n < 10 ? "0" : "") + n + tail);
        }

        H.tick = function () {
          if (H.off) return;
          var undo = false;
          try {
            var p = app.project;
            if (!p || !p.file) { H.path = null; return; }
            var rq = p.renderQueue, n = rq.numItems, now = new Date().getTime();
            var opened = p.file.fsName !== H.path;
            if (opened) {
              H.path = p.file.fsName; H.info = taskOf(p.file); H.looked = now; H.count = 0;
            } else if (!H.info && now - H.looked > 30000) {
              // The task folder or its Render folder may have been made since: look again.
              H.looked = now; H.info = taskOf(p.file);
              if (H.info) H.count = 0;
              opened = !!H.info;
            }
            if (!H.info) { H.count = n; return; }
            if (n < H.count) H.count = n;
            if (n === H.count && !opened) return;
            var from = opened ? 1 : H.count + 1;
            H.count = n;
            var next = 0;
            for (var i = from; i <= n; i++) {
              var it = rq.item(i), s = it.status;
              if (s !== RQItemStatus.QUEUED && s !== RQItemStatus.UNQUEUED && s !== RQItemStatus.NEEDS_OUTPUT) continue;
              for (var m = 1; m <= it.numOutputModules; m++) {
                var om = it.outputModule(m), cur = om.file;
                if (opened) {
                  // A project just opened: only outputs pointing outside the task folder (or nowhere).
                  if (cur && inside(cur, H.info.task)) continue;
                } else {
                  // Just added: unless it already has a task name in the Render folder.
                  if (cur && inside(cur, H.info.render) && decodeURI(cur.name).indexOf(H.info.base) === 0) continue;
                }
                if (!undo) { app.beginUndoGroup("Mongez: render output"); undo = true; }
                next = next ? next + 1 : nextNumber(H.info, rq);
                point(om, H.info, next);
              }
            }
          } catch (e) {}
          if (undo) { try { app.endUndoGroup(); } catch (e3) {} }
        };

        G.MongezRQ = H;
        H.task = app.scheduleTask("if ($.global.MongezRQ && $.global.MongezRQ.tick) $.global.MongezRQ.tick();", 2000, true);
      } catch (e) {}
    })();
    """#
}
