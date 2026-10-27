// TaskTimer Helper — runs inside After Effects. See AEBridge.swift in TaskTimer.
// The older helper TaskTimer put in with app.scheduleTask is switched off.
if ($.global.TaskTimerRQ) $.global.TaskTimerRQ.off = true;

var TaskTimerState = { proj: null, count: 0 };

function TaskTimerWords(n) { return decodeURI(n).toLowerCase().split(/[^a-z0-9]+/); }
function TaskTimerHas(n, list) {
  var w = TaskTimerWords(n);
  for (var i = 0; i < w.length; i++) for (var j = 0; j < list.length; j++) if (w[i] === list[j]) return true;
  return false;
}
// The task folder and its Render folder for the open project, or null.
function TaskTimerFolders() {
  var f = app.project ? app.project.file : null;
  if (!f) return null;
  var root = f.parent;
  if (TaskTimerHas(root.name, ["ae"]) && root.parent) root = root.parent;
  var subs = root.getFiles(function (x) { return x instanceof Folder; });
  var keys = ["render", "renders", "output"];
  for (var k = 0; k < keys.length; k++)
    for (var s = 0; s < subs.length; s++)
      if (TaskTimerHas(subs[s].name, [keys[k]])) return { root: root, render: subs[s] };
  return null;
}
function TaskTimerInside(file, folder) { return file && file.fsName.indexOf(folder.fsName + "/") === 0; }
function TaskTimerSafe(s) { return s.replace(/[\/\\:*?"<>|]/g, "-"); }

// Next free _vNN for this task: in the Render folder and in the queue.
function TaskTimerNextVersion(info, base) {
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

function TaskTimerPlace(om, cur, info, naming) {
  var name = decodeURI(cur.name);
  if (naming) {
    var base = TaskTimerSafe(decodeURI(info.root.name)) + "_v";
    if (name.indexOf(base) !== 0) {
      var dot = name.lastIndexOf(".");
      var ext = dot > 0 ? name.substr(dot) : "";
      var seq = name.match(/_?\[#+\]/);
      name = base + TaskTimerNextVersion(info, base) + (seq ? "_" + seq[0].replace(/^_/, "") : "") + ext;
    }
  }
  om.file = new File(info.render.fsName + "/" + name);
}

// Called by the extension every 2 s. Returns the open project's path ("" = none).
function TaskTimerTick(cfg) {
  var path = (app.project && app.project.file) ? app.project.file.fsName : "";
  if (!cfg.render) return path;
  try {
    var T = TaskTimerState;
    var info = TaskTimerFolders();
    if (!info) { T.proj = null; T.count = 0; return path; }
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
          if (TaskTimerInside(cur, info.root)) continue;
          TaskTimerPlace(om, cur, info, cfg.naming);
        } else if (!TaskTimerInside(cur, info.render) || cfg.naming) {
          TaskTimerPlace(om, cur, info, cfg.naming);
        }
      }
    }
    T.count = n;
  } catch (e) { }
  return path;
}
