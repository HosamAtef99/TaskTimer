// TaskTimer for Modhesh — background worker.
// Every minute:
//   1. Links Modhesh tasks to TaskTimer tasks when the names clearly match.
//   2. For linked tasks you've marked Done in TaskTimer, logs the time on Modhesh
//      (hours, deliverables, stars, No Challenges, Complete + your team leader as approver).
// Logging happens in a Modhesh tab (it opens one in the background if none is open,
// and closes it afterwards). The same hours are never sent twice.

importScripts('tasktimer.js');

const MODHESH = 'https://modhesh.social-eyez.com';
const ACTIVE = [1, 6]; // Pending to Start, In Progress

chrome.runtime.onInstalled.addListener(() => {
  chrome.alarms.create('tick', { periodInMinutes: 1 });
  chrome.alarms.create('modhesh', { periodInMinutes: 5 });
  readModhesh();
  chrome.storage.local.get('autoSubmit').then(({ autoSubmit }) => {
    if (autoSubmit === undefined) chrome.storage.local.set({ autoSubmit: true, autoLink: true });
  });
});
chrome.runtime.onStartup.addListener(() => {
  chrome.alarms.create('tick', { periodInMinutes: 1 });
  chrome.alarms.create('modhesh', { periodInMinutes: 5 });
  readModhesh();
});
chrome.alarms.onAlarm.addListener((a) => {
  if (a.name === 'tick') tick();
  if (a.name === 'modhesh') readModhesh();
});

// ───────────── 0. read Modhesh every 5 minutes (no tab needed) ─────────────

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

async function readModhesh() {
  await reloadIfUpdated();
  if (!(await TT.session())) return;
  checkIn();
  try {
    const now = new Date();
    const months = [[now.getMonth() + 1, now.getFullYear()]];
    const prev = new Date(now.getFullYear(), now.getMonth() - 1, 1);
    months.push([prev.getMonth() + 1, prev.getFullYear()]);
    const seen = new Map();
    for (const [m, y] of months) {
      const r = await fetch(`${MODHESH}/tasks/my?task_id=&priority=&start_month=${m}&start_year=${y}&is_weekend=`, {
        credentials: 'include',
        headers: { 'X-Requested-With': 'XMLHttpRequest', Accept: 'application/json' },
      });
      const type = r.headers.get('content-type') || '';
      if (!r.ok || !type.includes('json')) {
        console.log('[TaskTimer] Modhesh needs you to sign in there');
        return;
      }
      const j = await r.json();
      for (const [status, col] of Object.entries(j.columns || {})) {
        for (const c of col.cards || []) {
          const t = parseCardHtml(c.html || '', Number(status));
          if (t && t.title && !seen.has(t.code)) seen.set(t.code, t);
        }
      }
    }
    if (!seen.size) return;
    const uid = await TT.userId();
    const rows = [...seen.values()].map((t) => ({ ...t, user_id: uid, updated_at: new Date().toISOString() }));
    await TT.rest('POST', 'modhesh_tasks', rows, 'resolution=merge-duplicates,return=minimal');
    console.log(`[TaskTimer] read ${rows.length} Modhesh tasks`);
    tick();
  } catch (e) {
    console.log('[TaskTimer] reading Modhesh failed', e.message);
  }
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

async function myData() {
  const uid = await TT.userId();
  const [rows, tasks] = await Promise.all([
    TT.rest('GET', `modhesh_tasks?user_id=eq.${uid}&select=*`),
    TT.rest('GET', `tasks?user_id=eq.${uid}&deleted=eq.false&select=*&order=created_at.desc&limit=400`),
  ]);
  const byId = Object.fromEntries(tasks.map((t) => [t.id, t]));
  for (const t of tasks) t.display = t.parent_id && byId[t.parent_id] ? `${byId[t.parent_id].name} - ${t.name}` : t.name;
  return { uid, rows, tasks, byId };
}

// ───────────── 1. auto-link ─────────────

async function autoLink({ uid, rows, tasks }) {
  const taken = new Set(rows.filter((r) => r.task_id).map((r) => r.task_id));
  const since = Date.now() - 60 * 864e5;
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
    const total = liveSeconds(t);
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
      startedAt: t.started_at || t.created_at,
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
    const data = await myData();
    if (st.auto_link !== false) await autoLink(data);
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
  if (msg.type === 'signedIn') {
    checkIn().then(() => readModhesh()).then(() => reply({ ok: true }));
    return true;
  }
  return false;
});
