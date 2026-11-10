// TaskTimer for Modhesh — background worker.
// Reads your Modhesh tasks ONLY when you press "Check now" in the extension (Hosam's call: no
// automatic checking of Modhesh), and only when the Modhesh open in Chrome is yours.
// Every 2 minutes, for tasks you linked in TaskTimer and marked Done there, it logs the time on
// Modhesh (hours, deliverables, stars, challenge, Complete + the approver picked at Done) —
// switch that off in TaskTimer → Settings → Modhesh. This reads only TaskTimer's database;
// Modhesh is opened only when there is something to log.
// Logging happens in a Modhesh tab (it opens one in the background if none is open,
// and closes it afterwards). The same hours are never sent twice.

importScripts('tasktimer.js');

const MODHESH = 'https://modhesh.social-eyez.com';
const ACTIVE = [1, 6]; // Pending to Start, In Progress

function setup() {
  chrome.alarms.create('tick', { periodInMinutes: 2 });
  chrome.alarms.clear('modhesh');   // older versions read Modhesh every 5 minutes
  chrome.alarms.create('approvals', { periodInMinutes: 0.5 });   // leaders only: see approvalsTick
}
chrome.runtime.onInstalled.addListener(() => {
  setup();
  chrome.storage.local.get('autoSubmit').then(({ autoSubmit }) => {
    if (autoSubmit === undefined) chrome.storage.local.set({ autoSubmit: true, autoLink: true });
  });
});
chrome.runtime.onStartup.addListener(setup);
chrome.alarms.onAlarm.addListener((a) => {
  if (a.name === 'tick') { reloadIfUpdated(); tick(); }
  if (a.name === 'approvals') approvalsTick(false);
});

// ───────────── 0. read Modhesh when you press Check now (no tab needed) ─────────────

const STATUS = { 1: 'Pending to Start', 6: 'In Progress', 4: 'Completed', 5: 'Pending Approver', 2: 'Rejected' };

function decode(s) {
  return String(s || '').replace(/<[^>]*>/g, ' ').replace(/&amp;/g, '&').replace(/&quot;/g, '"').replace(/&#0?39;/g, "'")
    .replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&nbsp;/g, ' ').replace(/\s+/g, ' ').trim();
}

function parseCardHtml(html, status) {
  const code = (html.match(/data-post-task_id="([^"]+)"/) || [])[1];
  if (!code) return null;
  const title = decode((html.match(/class="[^"]*fw-bold fs-6[^"]*"[^>]*>([\s\S]*?)<\/(?:a|div|span|h\d)>/) || [])[1]);
  const client = decode((html.match(/class="text-truncate"[^>]*>([\s\S]*?)<\/(?:div|span)>/) || [])[1]);
  const m = decode(html).match(/(\d+)\s*Hours?\s*(\d+)\s*mins?/i);
  return {
    code, title, client, status,
    status_title: STATUS[status] || '',
    logged_seconds: m ? Number(m[1]) * 3600 + Number(m[2]) * 60 : null,
    view_url: (html.match(/data-action-url="([^"]*view-task)"/) || [])[1] || null,
  };
}

/// Tells TaskTimer the extension is installed and signed in.
async function checkIn() {
  try {
    const uid = await TT.userId();
    await TT.rest('POST', 'user_settings', [{
      user_id: uid,
      extension_seen_at: new Date().toISOString(),
      extension_version: chrome.runtime.getManifest().version,
    }], 'resolution=merge-duplicates,return=minimal');
  } catch (e) { /* table not there yet */ }
}

/// TaskTimer copies newer extension files into this folder when it updates; pick them up.
async function reloadIfUpdated() {
  try {
    const r = await fetch(chrome.runtime.getURL('manifest.json'), { cache: 'no-store' });
    const onDisk = (await r.json()).version;
    if (onDisk && onDisk !== chrome.runtime.getManifest().version) chrome.runtime.reload();
  } catch (e) { /* ignore */ }
}

/// Tells TaskTimer what the last read of Modhesh found (shown in Settings → Modhesh).
async function report(text) {
  try {
    const uid = await TT.userId();
    await TT.rest('POST', 'user_settings', [{ user_id: uid, modhesh_status: text, modhesh_read_at: new Date().toISOString() }],
      'resolution=merge-duplicates,return=minimal');
  } catch (e) { /* older database */ }
}

let lastRead = 0;
async function readModhesh(force) {
  await reloadIfUpdated();
  if (!(await TT.session())) return;
  if (!force && Date.now() - lastRead < 60000) return;
  lastRead = Date.now();
  checkIn();
  try {
    const now = new Date();
    const months = [[now.getMonth() + 1, now.getFullYear()]];
    const prev = new Date(now.getFullYear(), now.getMonth() - 1, 1);
    months.push([prev.getMonth() + 1, prev.getFullYear()]);
    const seen = new Map();
    let owner = '';
    for (const [m, y] of months) {
      const r = await fetch(`${MODHESH}/tasks/my?task_id=&priority=&start_month=${m}&start_year=${y}&is_weekend=`, {
        credentials: 'include',
        headers: { 'X-Requested-With': 'XMLHttpRequest', Accept: 'application/json' },
      });
      const type = r.headers.get('content-type') || '';
      if (!r.ok || !type.includes('json')) {
        console.log('[TaskTimer] Modhesh needs you to sign in there');
        await report('Not signed in to Modhesh in Chrome — open Modhesh and sign in.');
        return;
      }
      const j = await r.json();
      for (const [status, col] of Object.entries(j.columns || {})) {
        for (const c of col.cards || []) {
          const t = parseCardHtml(c.html || '', Number(status));
          if (t && t.title && !seen.has(t.code)) seen.set(t.code, t);
          if (!owner) owner = assigneeOf(c.html || '');
        }
      }
    }
    const active = [...seen.values()].filter((t) => ACTIVE.includes(t.status)).length;
    if (!seen.size) { await report('Modhesh has no tasks for you this month or last.'); return; }
    const uid = await TT.userId();

    // Only take Modhesh tasks that belong to this TaskTimer account.
    if (!(await sameOwner(uid, owner))) {
      console.log(`[TaskTimer] Modhesh is signed in as "${owner}", not this TaskTimer account — not taking its tasks`);
      await report(`Modhesh in Chrome is “${owner}”, not this account — its tasks aren't taken.`);
      return;
    }
    await report(`${seen.size} tasks read from Modhesh${owner ? ` (${owner})` : ''} · ${active} pending or in progress.`);

    // Only send what changed since last time (remembered per account).
    const key = `sentModhesh_${uid}`;
    const { [key]: sentModhesh = {} } = await chrome.storage.local.get(key);
    const changed = [...seen.values()].filter((t) => sentModhesh[t.code] !== JSON.stringify(t));
    if (!changed.length) return;
    const rows = changed.map((t) => ({ ...t, user_id: uid, updated_at: new Date().toISOString() }));
    await TT.rest('POST', 'modhesh_tasks', rows, 'resolution=merge-duplicates,return=minimal');
    for (const t of changed) sentModhesh[t.code] = JSON.stringify(t);
    await chrome.storage.local.set({ [key]: sentModhesh });
    console.log(`[TaskTimer] sent ${rows.length} changed Modhesh tasks`);
    tick();
  } catch (e) {
    console.log('[TaskTimer] reading Modhesh failed', e.message);
  }
}

// ───────────── whose Modhesh is this? ─────────────

/// The person the Modhesh cards are assigned to ("Hossam Atef").
function assigneeOf(html) {
  return decode((html.match(/class="text-gray-800 fw-semibold fs-7[^"]*"[^>]*>([\s\S]*?)<\/(?:div|span|a)>/) || [])[1]);
}

/// Every word of the shorter name appears in the longer one ("Abdelkhalek" ~ "Ahmed Abdelkhalek").
function namesMatch(a, b) {
  const A = [...words(a)], B = [...words(b)];
  if (!A.length || !B.length) return false;
  const [short, long] = A.length <= B.length ? [A, new Set(B)] : [B, new Set(A)];
  return short.every((w) => long.has(w));
}

/// True when the Modhesh open in Chrome is this TaskTimer account's person — matched by name
/// (TaskTimer name or email), or confirmed in TaskTimer → Settings → Modhesh.
async function sameOwner(uid, owner) {
  const st = await TT.settings(true);
  // "Clear & re-check" in TaskTimer: forget what was sent, send everything again.
  const resetKey = `modheshReset_${uid}`;
  const { [resetKey]: seenReset } = await chrome.storage.local.get(resetKey);
  if (st.modhesh_reset_at && st.modhesh_reset_at !== seenReset) {
    await chrome.storage.local.remove(`sentModhesh_${uid}`);
    await chrome.storage.local.set({ [resetKey]: st.modhesh_reset_at });
  }
  let ok;
  if (!owner) {
    ok = !st.modhesh_mismatch;          // no cards to tell from: keep the last answer
  } else if (st.modhesh_name) {
    ok = norm(st.modhesh_name) === norm(owner);
  } else {
    const me = (await TT.rest('GET', `profiles?id=eq.${uid}&select=full_name,email`))[0] || {};
    const fromEmail = String(me.email || '').split('@')[0].replace(/[._-]+/g, ' ');
    ok = namesMatch(me.full_name, owner) || namesMatch(fromEmail, owner);
  }
  if (owner && (owner !== st.modhesh_seen_name || ok === !!st.modhesh_mismatch)) {
    await TT.rest('POST', 'user_settings', [{ user_id: uid, modhesh_seen_name: owner, modhesh_mismatch: !ok }],
      'resolution=merge-duplicates,return=minimal').catch(() => {});
  }
  if (!ok) {
    // Remove Modhesh tasks this account picked up from someone else's Modhesh (never linked ones).
    await TT.rest('DELETE', `modhesh_tasks?user_id=eq.${uid}&task_id=is.null`, null, 'return=minimal').catch(() => {});
    await chrome.storage.local.remove(`sentModhesh_${uid}`);
  }
  return ok;
}

// ───────────── helpers ─────────────

function liveSeconds(t) {
  let s = Number(t.seconds) || 0;
  if (t.running_since) s += Math.max(0, (Date.now() - new Date(t.running_since).getTime()) / 1000);
  return Math.max(0, s);
}

function norm(s) {
  return String(s || '').toLowerCase().replace(/[^\p{L}\p{N}]+/gu, ' ').trim();
}

function words(s) { return new Set(norm(s).split(' ').filter((w) => w.length > 1)); }

/// Strong match only: same name, one name inside the other, or most words shared.
function strongMatch(a, b) {
  const A = norm(a), B = norm(b);
  if (!A || !B) return 0;
  if (A === B) return 1;
  if ((A.length >= 6 && B.includes(A)) || (B.length >= 6 && A.includes(B))) return 0.9;
  const wa = words(a), wb = words(b);
  let inter = 0;
  wa.forEach((w) => { if (wb.has(w)) inter++; });
  const j = inter / new Set([...wa, ...wb]).size;
  return j >= 0.6 ? j : 0;
}

// Kept small on purpose (the free database has a monthly download allowance):
// only active Modhesh tasks, and only the TaskTimer tasks they're linked to.
async function withNames(tasks) {
  const known = new Map(tasks.map((t) => [t.id, t]));
  const missing = [...new Set(tasks.map((t) => t.parent_id).filter((p) => p && !known.has(p)))];
  if (missing.length) {
    const parents = await TT.rest('GET', `tasks?id=in.(${missing.join(',')})&select=id,name`);
    for (const p of parents) known.set(p.id, p);
  }
  for (const t of tasks) t.display = t.parent_id && known.get(t.parent_id) ? `${known.get(t.parent_id).name} - ${t.name}` : t.name;
  return tasks;
}

async function myData(needCandidates) {
  const uid = await TT.userId();
  const rows = await TT.rest('GET',
    `modhesh_tasks?user_id=eq.${uid}&status=in.(1,6)&select=code,title,status,logged_seconds,submitted_seconds,task_id`);
  const ids = [...new Set(rows.map((r) => r.task_id).filter(Boolean))];
  const linked = ids.length ? await TT.rest('GET', `tasks?id=in.(${ids.join(',')})&deleted=eq.false&select=*`) : [];
  let tasks = linked;
  if (needCandidates && rows.some((r) => !r.task_id)) {
    const since = new Date(Date.now() - 21 * 864e5).toISOString();
    const recent = await TT.rest('GET',
      `tasks?user_id=eq.${uid}&deleted=eq.false&created_at=gt.${encodeURIComponent(since)}&select=id,name,parent_id,created_at&order=created_at.desc&limit=120`);
    tasks = [...linked, ...recent.filter((t) => !ids.includes(t.id))];
  }
  await withNames(tasks);
  const byId = Object.fromEntries(tasks.map((t) => [t.id, t]));
  return { uid, rows, tasks, byId };
}

// ───────────── 1. auto-link ─────────────

async function autoLink({ uid, rows, tasks }) {
  const taken = new Set(rows.filter((r) => r.task_id).map((r) => r.task_id));
  const since = Date.now() - 21 * 864e5;
  const pool = tasks.filter((t) => !taken.has(t.id) && new Date(t.created_at).getTime() > since);
  for (const r of rows) {
    if (r.task_id || !ACTIVE.includes(r.status)) continue;
    const hits = pool.map((t) => ({ t, s: strongMatch(r.title, t.display) })).filter((x) => x.s > 0)
      .sort((a, b) => b.s - a.s);
    // Only when there's exactly one clear candidate.
    if (hits.length !== 1 && !(hits.length > 1 && hits[0].s - hits[1].s >= 0.25)) continue;
    const t = hits[0].t;
    await TT.rest('PATCH', `modhesh_tasks?user_id=eq.${uid}&code=eq.${encodeURIComponent(r.code)}`,
      { task_id: t.id, auto_linked: true }, 'return=minimal');
    r.task_id = t.id;
    taken.add(t.id);
    pool.splice(pool.indexOf(t), 1);
  }
}

// ───────────── 2. what needs logging ─────────────

function jobsFrom({ rows, byId }, st = {}) {
  const jobs = [];
  for (const r of rows) {
    const t = r.task_id && byId[r.task_id];
    // Pending to Start tasks are moved to In Progress first, then logged.
    if (!t || t.status !== 'complete' || !ACTIVE.includes(r.status)) continue;
    if (t.modhesh_manual) continue;   // marked "Linked to Modhesh" by hand: entered there already
    // A group (several tasks → one Modhesh task): its tasks' hours added up, from Mongez.
    const total = t.is_group ? Math.max(0, Number(t.group_seconds) || 0) : liveSeconds(t);
    const already = Math.max(Number(r.submitted_seconds) || 0, Number(r.logged_seconds) || 0);
    const toLog = total - already;
    if (toLog < 60) continue;
    jobs.push({
      code: r.code,
      title: r.title,
      task: t.display,
      total,
      toLog,
      deliverables: t.deliverables ?? st.default_deliverables ?? 1,
      rating: t.rating ?? st.default_rating ?? 5,
      challenge: t.challenge || st.challenge || 1,
      complete: true,
      approver: t.approver_name || null,   // picked at Done; null = the team leader
      startDate: t.work_date || null,      // the day picked at Done → the Modhesh task's Start Date
    });
  }
  return jobs;
}

let pending = [];
let ownTab = null;
let running = false;

async function tick() {
  if (running) return;
  const s = await TT.session();
  if (!s) return;
  const { attempts = {} } = await chrome.storage.local.get(['attempts']);
  running = true;
  try {
    const st = await TT.settings();   // TaskTimer → Settings → Modhesh
    if (st.modhesh_mismatch) return;  // Modhesh in Chrome is someone else's
    // Automatic linking by name is gone (it linked wrong tasks): undo the ones it made
    // that haven't been sent yet, once per account.
    const uid = await TT.userId();
    const flag = `autoLinksUndone_${uid}`;
    if (!(await chrome.storage.local.get(flag))[flag]) {
      await TT.rest('PATCH', `modhesh_tasks?user_id=eq.${uid}&auto_linked=eq.true&submitted_at=is.null`,
        { task_id: null, auto_linked: false }, 'return=minimal').catch(() => {});
      await chrome.storage.local.set({ [flag]: true });
    }
    const data = await myData(false);
    if (st.auto_submit === false) return;
    // Don't retry the same task more often than every 15 minutes.
    const now = Date.now();
    pending = jobsFrom(data, st).filter((j) => !attempts[j.code] || now - attempts[j.code] > 15 * 60000);
    if (!pending.length) return;
    for (const j of pending) attempts[j.code] = now;
    await chrome.storage.local.set({ attempts });

    const tabs = await chrome.tabs.query({ url: `${MODHESH}/tasks/my*` });
    if (tabs.length) {
      chrome.tabs.sendMessage(tabs[0].id, { type: 'jobs', jobs: pending }).catch(() => {});
    } else {
      const tab = await chrome.tabs.create({ url: `${MODHESH}/tasks/my`, active: false, pinned: true });
      ownTab = tab.id;
      // The page asks for its jobs when it loads.
    }
  } catch (e) {
    console.log('[TaskTimer] tick failed', e.message);
  } finally {
    running = false;
  }
}

// ───────────── approvals (team leaders) ─────────────
// A leader approves the team's tasks on Modhesh → Tasks → Approve Tasks. Mongez shows that list
// and has Approve / Approve All / Return (with a reason). Nothing is approved by itself: only
// rows the leader pressed in Mongez (modhesh_approvals.action). Mongez asks by writing a new time
// in user_settings.approvals_request; every 30 s a leader's extension looks at that one value
// (TaskTimer's database only) and reads Modhesh only when it changed.

const APPROVALS = `${MODHESH}/timesheets/timesheetapproval-requests`;

async function amLeader(uid) {
  const { ttRole = {} } = await chrome.storage.local.get('ttRole');
  if (ttRole.uid === uid && Date.now() - ttRole.at < 6 * 3600e3) return ttRole.role === 'leader';
  let role = '';
  try { role = ((await TT.rest('GET', `profiles?id=eq.${uid}&select=role`))[0] || {}).role || ''; } catch (e) { return false; }
  await chrome.storage.local.set({ ttRole: { uid, role, at: Date.now() } });
  return role === 'leader';
}

async function approvalsReport(uid, text) {
  await TT.rest('POST', 'user_settings', [{ user_id: uid, approvals_status: text, approvals_read_at: new Date().toISOString() }],
    'resolution=merge-duplicates,return=minimal').catch(() => {});
}

/// The rows of Modhesh's "Tasks Approval Requests" table, or null when Modhesh isn't signed in.
async function fetchApprovals() {
  const r = await fetch(`${APPROVALS}?draw=1&start=0&length=500&search%5Bvalue%5D=&is_weekend=`, {
    credentials: 'include',
    headers: { 'X-Requested-With': 'XMLHttpRequest', Accept: 'application/json' },
  });
  const type = r.headers.get('content-type') || '';
  if (!r.ok || !type.includes('json')) return null;
  const j = await r.json();
  const out = [];
  for (const d of j.data || []) {
    const code = (String(d.actions || '').match(/request-complete\/([^"'\s<]+)/) || [])[1]
      || (String(d.title || '').match(/data-post-task_id="([^"]+)"/) || [])[1];
    if (!code) continue;
    const m = decode(d.actual_spent).match(/(\d+)\s*Hours?\s*(\d+)\s*mins?/i);
    out.push({
      code,
      client: decode(d.client),
      title: decode(d.title),
      assignee: decode(String(d.requested_by || '').replace(/<span[\s\S]*?<\/span>/g, '')),
      assigned_by: decode(String(d.created_by || '').split(/<br\s*\/?>/i)[0]),
      start_date: decode(d.start_date),
      completed_at: decode(d.task_completed_at),
      seconds: m ? Number(m[1]) * 3600 + Number(m[2]) * 60 : null,
    });
  }
  return out;
}

/// Return (with a reason): Modhesh's own Return window is a form loaded from /tasks/return-time.
/// It's read here and sent with the reason in its text box(es).
async function returnOnModhesh(code, reason) {
  const page = await fetch(APPROVALS, { credentials: 'include' }).then((r) => r.text());
  const csrf = (page.match(/<meta name="csrf-token" content="([^"]+)"/) || [])[1];
  if (!csrf) return 'Not signed in to Modhesh in Chrome.';
  const head = { 'X-Requested-With': 'XMLHttpRequest', 'X-CSRF-TOKEN': csrf, 'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8' };
  const modal = await fetch(`${MODHESH}/tasks/return-time`, {
    method: 'POST', credentials: 'include', headers: head,
    body: new URLSearchParams({ ajaxModal: '1', task_id: code }).toString(),
  }).then((r) => r.text());
  const action = (modal.match(/<form[^>]*\saction="([^"]+)"/i) || [])[1];
  if (!action) return 'Modhesh\'s Return window wasn\'t understood (no form). Return it on Modhesh.';
  const attr = (tag, name) => (tag.match(new RegExp(`\\s${name}="([^"]*)"`, 'i')) || [])[1];
  const body = new URLSearchParams();
  const names = [];
  let filled = 0;
  for (const tag of modal.match(/<input[^>]*>/gi) || []) {
    const name = attr(tag, 'name'); if (!name) continue;
    const type = (attr(tag, 'type') || 'text').toLowerCase();
    names.push(`${name}:${type}`);
    if (type === 'hidden') body.set(name, decode(attr(tag, 'value') || ''));
    else if (type === 'text') { body.set(name, reason); filled++; }
  }
  for (const tag of modal.match(/<textarea[^>]*>/gi) || []) {
    const name = attr(tag, 'name'); if (!name) continue;
    names.push(`${name}:textarea`);
    body.set(name, reason); filled++;
  }
  if (!body.has('_token')) body.set('_token', csrf);
  if (!body.has('task_id')) body.set('task_id', code);
  if (!filled) return `Modhesh's Return window has no reason box (${names.join(', ') || 'no fields'}). Return it on Modhesh.`;
  const url = action.startsWith('http') ? action : MODHESH + (action.startsWith('/') ? '' : '/') + action;
  const r = await fetch(url, { method: 'POST', credentials: 'include', headers: head, body: body.toString() });
  return r.ok ? '' : `Modhesh answered ${r.status} to Return (${names.join(', ')}).`;
}

let approvalsBusy = false;
async function approvalsTick(force) {
  if (approvalsBusy) return;
  approvalsBusy = true;
  try {
    if (!(await TT.session())) return;
    const uid = await TT.userId();
    if (!(await amLeader(uid))) return;
    const st = await TT.settings(true);
    const key = `approvalsRequest_${uid}`;
    const { [key]: seen } = await chrome.storage.local.get(key);
    if (!force && (!st.approvals_request || st.approvals_request === seen)) return;
    await chrome.storage.local.set({ [key]: st.approvals_request || '' });
    if (st.modhesh_mismatch) { await approvalsReport(uid, 'Modhesh in Chrome isn\'t this account\'s — nothing read.'); return; }

    let list = await fetchApprovals();
    if (!list) { await approvalsReport(uid, 'Not signed in to Modhesh in Chrome — open Modhesh and sign in.'); return; }

    // What the leader pressed in Mongez.
    const asked = await TT.rest('GET', `modhesh_approvals?user_id=eq.${uid}&action=not.is.null&done_at=is.null&select=code,action,reason,title`);
    const notes = {};
    let did = 0;
    for (const a of asked) {
      if (!list.some((t) => t.code === a.code)) continue;   // not waiting any more
      try {
        if (a.action === 'approve') {
          const r = await fetch(`${MODHESH}/timesheets/request-complete/${encodeURIComponent(a.code)}`, { credentials: 'include' });
          if (!r.ok) notes[a.code] = `Modhesh answered ${r.status}.`;
        } else if (a.action === 'return') {
          if (!String(a.reason || '').trim()) notes[a.code] = 'A reason is needed to return a task.';
          else { const err = await returnOnModhesh(a.code, a.reason.trim()); if (err) notes[a.code] = err; }
        }
        did++;
      } catch (e) { notes[a.code] = e.message || 'Failed'; }
    }
    if (did) list = (await fetchApprovals()) || list;

    // Results: gone from Modhesh's list = done.
    const now = new Date().toISOString();
    let ok = 0, failed = 0;
    for (const a of asked) {
      const still = list.some((t) => t.code === a.code);
      const patch = still
        ? { action: null, note: notes[a.code] || 'Still waiting on Modhesh — try again, or do it there.' }
        : { pending: false, done_at: now, note: a.action === 'return' ? 'Returned' : 'Approved' };
      still ? failed++ : ok++;
      await TT.rest('PATCH', `modhesh_approvals?user_id=eq.${uid}&code=eq.${encodeURIComponent(a.code)}`, patch, 'return=minimal').catch(() => {});
    }
    // The list as it is now.
    await TT.rest('PATCH', `modhesh_approvals?user_id=eq.${uid}&pending=eq.true`, { pending: false }, 'return=minimal').catch(() => {});
    if (list.length) {
      await TT.rest('POST', 'modhesh_approvals', list.map((t) => ({ ...t, user_id: uid, pending: true, updated_at: now })),
        'resolution=merge-duplicates,return=minimal');
    }
    const parts = [`${list.length} waiting for your approval`];
    if (ok) parts.unshift(`${ok} done on Modhesh`);
    if (failed) parts.unshift(`${failed} didn't go through`);
    await approvalsReport(uid, parts.join(' · '));
    if (ok || failed) {
      chrome.notifications.create(`tt-approvals-${Date.now()}`, {
        type: 'basic', iconUrl: 'icons/128.png',
        title: failed ? 'Some approvals didn\'t go through' : 'Approved on Modhesh ✓',
        message: parts.join(' · '),
      });
    }
  } catch (e) {
    console.log('[TaskTimer] approvals failed', e.message);
  } finally {
    approvalsBusy = false;
  }
}

// ───────────── messages from the Modhesh page ─────────────

chrome.runtime.onMessage.addListener((msg, sender, reply) => {
  if (msg.type === 'getJobs') {
    reply({ jobs: pending });
    return false;
  }
  if (msg.type === 'jobRetry') {
    // Moved to In Progress; the page reloads and logs it straight after (at most twice).
    const j = pending.find((p) => p.code === msg.job.code);
    if (j) {
      j.restarts = (j.restarts || 0) + 1;
      if (j.restarts > 2) pending = pending.filter((p) => p !== j);
    }
    reply({ ok: true });
    return false;
  }
  if (msg.type === 'jobDone') {
    (async () => {
      const uid = await TT.userId();
      const j = msg.job;
      const patch = msg.ok
        ? { submitted_seconds: j.total, submitted_at: new Date().toISOString(), submit_note: msg.note || 'Sent to approver' }
        : { submit_note: msg.note || 'Failed' };
      await TT.rest('PATCH', `modhesh_tasks?user_id=eq.${uid}&code=eq.${encodeURIComponent(j.code)}`, patch, 'return=minimal')
        .catch(() => {});
      pending = pending.filter((p) => p.code !== j.code);
      const h = Math.round((j.toLog / 3600) * 100) / 100;
      chrome.notifications.create(`tt-${j.code}-${Date.now()}`, {
        type: 'basic',
        iconUrl: 'icons/128.png',
        title: msg.ok ? 'Logged on Modhesh ✓' : 'Couldn\'t log on Modhesh',
        message: msg.ok ? `${j.title} — ${h} h, sent to your approver` : `${j.title}: ${msg.note || 'try again'}`,
      });
      reply({ ok: true });
    })();
    return true;
  }
  if (msg.type === 'allDone') {
    if (ownTab !== null && sender.tab && sender.tab.id === ownTab) {
      chrome.tabs.remove(ownTab).catch(() => {});
      ownTab = null;
    }
    return false;
  }
  if (msg.type === 'tickNow') {
    tick().then(() => reply({ ok: true }));
    return true;
  }
  if (msg.type === 'readNow') {
    // "Check now" in the extension: read Modhesh, then log anything finished.
    readModhesh(true).then(() => tick()).then(() => approvalsTick(true)).then(() => reply({ ok: true }));
    return true;
  }
  if (msg.type === 'signedIn') {
    checkIn().then(() => reply({ ok: true }));
    return true;
  }
  return false;
});
