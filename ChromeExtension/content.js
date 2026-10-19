// TaskTimer on Modhesh.
// 1. Sends your Modhesh tasks to TaskTimer (so you can link them there).
// 2. Adds a "Fill from TaskTimer" bar to Log Time and to Task Details.
// It only fills the form — you check it and press Save yourself.

(() => {
  const STATUS = { 1: 'Pending to Start', 6: 'In Progress', 4: 'Completed', 5: 'Pending Approver', 2: 'Rejected' };
  const log = (...a) => console.log('[TaskTimer]', ...a);

  // ───────────── Helpers ─────────────

  const pad = (n) => String(n).padStart(2, '0');
  const isoDay = (d) => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
  const hours = (s) => Math.round((s / 3600) * 100) / 100;

  function liveSeconds(t) {
    let s = Number(t.seconds) || 0;
    if (t.running_since) s += Math.max(0, (Date.now() - new Date(t.running_since).getTime()) / 1000);
    return Math.max(0, s);
  }

  function words(s) {
    return new Set(String(s || '').toLowerCase().split(/[^\p{L}\p{N}]+/u).filter((w) => w.length > 1));
  }

  function similarity(a, b) {
    const A = words(a), B = words(b);
    if (!A.size || !B.size) return 0;
    let inter = 0;
    A.forEach((w) => { if (B.has(w)) inter++; });
    return inter / new Set([...A, ...B]).size;
  }

  function setValue(el, value) {
    if (!el) return;
    el.focus();
    el.value = value;
    el.dispatchEvent(new Event('input', { bubbles: true }));
    el.dispatchEvent(new Event('change', { bubbles: true }));
    el.blur();
  }

  function el(tag, attrs = {}, ...children) {
    const e = document.createElement(tag);
    for (const [k, v] of Object.entries(attrs)) {
      if (k === 'class') e.className = v;
      else if (k.startsWith('on')) e.addEventListener(k.slice(2), v);
      else e.setAttribute(k, v);
    }
    for (const c of children) e.append(c);
    return e;
  }

  // ───────────── Data from TaskTimer ─────────────

  let myTasksCache = null;
  async function myTasks(force) {
    if (myTasksCache && !force && Date.now() - myTasksCache.at < 30000) return myTasksCache.list;
    const uid = await TT.userId();
    const list = await TT.rest('GET',
      `tasks?user_id=eq.${uid}&deleted=eq.false&select=id,name,client,status,seconds,running_since,deliverables,rating,parent_id,started_at,created_at&order=created_at.desc&limit=400`);
    const byId = Object.fromEntries(list.map((t) => [t.id, t]));
    for (const t of list) t.display = t.parent_id && byId[t.parent_id] ? `${byId[t.parent_id].name} - ${t.name}` : t.name;
    myTasksCache = { at: Date.now(), list };
    return list;
  }

  async function modheshRow(code) {
    const uid = await TT.userId();
    const rows = await TT.rest('GET', `modhesh_tasks?user_id=eq.${uid}&code=eq.${encodeURIComponent(code)}&select=*`);
    return rows[0] || null;
  }

  async function link(code, taskId, title) {
    const uid = await TT.userId();
    const row = { user_id: uid, code, task_id: taskId };
    if (title) row.title = title;
    await TT.rest('POST', 'modhesh_tasks', [row], 'resolution=merge-duplicates,return=minimal');
  }

  let leaderCache;
  async function leaderName() {
    if (leaderCache !== undefined) return leaderCache;
    try {
      const uid = await TT.userId();
      const me = await TT.rest('GET', `profiles?id=eq.${uid}&select=team_id`);
      const team = me[0] && me[0].team_id;
      if (!team) return (leaderCache = null);
      const leaders = await TT.rest('GET', `profiles?team_id=eq.${team}&role=eq.leader&select=full_name,email`);
      leaderCache = leaders[0] || null;
    } catch (e) {
      leaderCache = null;
    }
    return leaderCache;
  }

  // ───────────── 1. Send Modhesh tasks to TaskTimer ─────────────

  function parseCard(html, status) {
    const doc = new DOMParser().parseFromString(html, 'text/html');
    const link = doc.querySelector('[data-act="drawer-modal"][data-post-task_id]') || doc.querySelector('[data-post-task_id]');
    const code = link && link.getAttribute('data-post-task_id');
    if (!code) return null;
    const title = ((doc.querySelector('.fw-bold.fs-6') || link).textContent || '').trim();
    const client = ((doc.querySelector('.text-truncate') || {}).textContent || '').trim();
    const m = (doc.body.textContent || '').match(/(\d+)\s*Hours?\s*(\d+)\s*mins?/i);
    return {
      code, title, client, status,
      status_title: STATUS[status] || '',
      logged_seconds: m ? Number(m[1]) * 3600 + Number(m[2]) * 60 : null,
      view_url: link.getAttribute('data-action-url') || null,
    };
  }

  async function readMonth(month, year) {
    const r = await fetch(`/tasks/my?task_id=&priority=&start_month=${month}&start_year=${year}&is_weekend=`, {
      headers: { 'X-Requested-With': 'XMLHttpRequest', Accept: 'application/json' },
      credentials: 'same-origin',
    });
    if (!r.ok) return [];
    const j = await r.json().catch(() => ({}));
    const out = [];
    for (const [status, col] of Object.entries(j.columns || {})) {
      for (const c of col.cards || []) {
        const t = parseCard(c.html || '', Number(status));
        if (t) out.push(t);
      }
    }
    return out;
  }

  let syncing = false;
  async function syncModhesh() {
    if (syncing || !(await TT.session())) return;
    syncing = true;
    try {
      const now = new Date();
      const prev = new Date(now.getFullYear(), now.getMonth() - 1, 1);
      const tasks = [...(await readMonth(now.getMonth() + 1, now.getFullYear())),
                     ...(await readMonth(prev.getMonth() + 1, prev.getFullYear()))];
      const seen = new Map();
      for (const t of tasks) if (!seen.has(t.code)) seen.set(t.code, t);
      if (!seen.size) return;
      const uid = await TT.userId();
      const rows = [...seen.values()].map((t) => ({ ...t, user_id: uid, updated_at: new Date().toISOString() }));
      await TT.rest('POST', 'modhesh_tasks', rows, 'resolution=merge-duplicates,return=minimal');
      log(`sent ${rows.length} Modhesh tasks to TaskTimer`);
    } catch (e) {
      log('sync failed:', e.message);
    } finally {
      syncing = false;
    }
  }

  // ───────────── 2. Fill bar ─────────────

  function bar(form, kind) {
    const box = el('div', { class: 'tt-bar' }, el('div', { class: 'tt-title' }, 'TaskTimer'));
    const body = el('div', { class: 'tt-body' }, 'Loading…');
    box.append(body);
    form.prepend(box);
    return body;
  }

  function signedOut(body) {
    body.replaceChildren('Sign in to TaskTimer from the extension button in Chrome\'s toolbar to fill this from your timer.');
  }

  async function chooser(body, code, title, onPick) {
    const tasks = await myTasks();
    const ranked = tasks
      .map((t) => ({ t, score: similarity(title, t.display) }))
      .sort((a, b) => b.score - a.score || new Date(b.t.created_at) - new Date(a.t.created_at));
    const select = el('select', { class: 'tt-select' },
      el('option', { value: '' }, 'Choose the TaskTimer task…'),
      ...ranked.slice(0, 60).map(({ t }) => el('option', { value: t.id }, `${t.display}  ·  ${hours(liveSeconds(t))} h`)));
    if (ranked[0] && ranked[0].score >= 0.34) select.value = ranked[0].t.id;
    const btn = el('button', { type: 'button', class: 'tt-btn', onclick: async () => {
      if (!select.value) return;
      btn.disabled = true;
      try {
        await link(code, select.value, title);
        await onPick(tasks.find((t) => t.id === select.value));
      } catch (e) {
        body.replaceChildren(`Couldn't link: ${e.message}`);
      }
    } }, 'Link & Fill');
    body.replaceChildren(el('div', {}, 'Which TaskTimer task is this?'), el('div', { class: 'tt-row' }, select, btn));
  }

  // Log Time

  async function decorateLogTime(form) {
    const code = (form.querySelector('[name=task_id]') || {}).value;
    if (!code) return;
    const body = bar(form, 'log');
    if (!(await TT.session())) return signedOut(body);
    const title = (document.querySelector(`[data-post-task_id="${CSS.escape(code)}"]`) || {}).textContent?.trim() || '';
    try {
      const row = await modheshRow(code);
      const tasks = await myTasks(true);
      const linked = row && row.task_id && tasks.find((t) => t.id === row.task_id);
      if (linked) showLogTime(form, body, linked, row);
      else await chooser(body, code, (row && row.title) || title, async (t) => showLogTime(form, body, t, await modheshRow(code)));
    } catch (e) {
      body.replaceChildren(`Couldn't reach TaskTimer: ${e.message}`);
    }
  }

  function showLogTime(form, body, t, row) {
    const total = liveSeconds(t);
    const logged = (row && Number(row.logged_seconds)) || 0;
    const toLog = Math.max(0, total - logged);
    const deliverables = t.deliverables ?? 1;
    const rating = t.rating ?? 5;
    const complete = t.status === 'complete';

    const info = el('div', {},
      el('b', {}, t.display), el('br'),
      `${hours(total)} h in TaskTimer` + (logged ? ` − ${hours(logged)} h already logged here = ${hours(toLog)} h` : '') +
      ` · ${deliverables} deliverable${deliverables === 1 ? '' : 's'} · ${'★'.repeat(rating)}` +
      (complete ? ' · Completed' : ''));
    const btn = el('button', { type: 'button', class: 'tt-btn', onclick: () => fillLogTime(form, body, { toLog, deliverables, rating, complete }) },
      'Fill from TaskTimer');
    body.replaceChildren(info, el('div', { class: 'tt-row' }, btn));
  }

  async function fillLogTime(form, body, v) {
    const mins = Math.round(v.toLog / 60);
    setValue(form.querySelector('[name=actual_spent_hours]'), String(Math.floor(mins / 60)));
    setValue(form.querySelector('[name=actual_spent_mins]'), String(mins % 60));
    setValue(form.querySelector('[name=task_deliverables]'), String(v.deliverables));

    const star = form.querySelector(`i[data-value="${v.rating}"]`);
    if (star) star.click();
    setValue(form.querySelector('[name=task_rating]'), String(v.rating));

    const challenges = [...form.querySelectorAll('[name="task_challenge[]"]')];
    if (challenges.length && !challenges.some((c) => c.checked)) {
      const none = challenges.find((c) => c.value === '1');
      if (none) none.click();
    }

    let approverNote = '';
    const done = form.querySelector('[name=status]');
    if (v.complete && done && !done.checked) done.click();
    if (v.complete) {
      await new Promise((r) => setTimeout(r, 400));
      const select = form.querySelector('[name=approver]');
      const leader = await leaderName();
      if (select && leader) {
        const want = [leader.full_name, leader.email].filter(Boolean).map((s) => s.toLowerCase());
        const opt = [...select.options].find((o) => {
          const text = o.textContent.trim().toLowerCase();
          return text && want.some((w) => text === w || text.includes(w) || (w.includes(text) && text.length > 4) ||
                                          similarity(text, w) >= 0.5);
        });
        if (opt) {
          select.value = opt.value;
          select.dispatchEvent(new Event('change', { bubbles: true }));
          approverNote = ` · Approver: ${opt.textContent.trim()}`;
        } else {
          approverNote = ` · Couldn't find ${leader.full_name || 'your leader'} in the Approver list — pick them`;
        }
      }
    }
    body.replaceChildren(el('div', { class: 'tt-done' },
      `Filled ✓ ${Math.floor(mins / 60)}h ${mins % 60}m${approverNote}. Check it, then press Save.`));
  }

  // Task Details (Start Date)

  async function decorateDetails(form) {
    const code = (form.querySelector('[name=task_id]') || {}).value;
    if (!code) return;
    const body = bar(form, 'details');
    if (!(await TT.session())) return signedOut(body);
    try {
      const row = await modheshRow(code);
      const tasks = await myTasks(true);
      const t = row && row.task_id && tasks.find((x) => x.id === row.task_id);
      const title = (form.querySelector('[name=title]') || {}).value || (row && row.title) || '';
      if (t) showDetails(form, body, t);
      else await chooser(body, code, title, async (picked) => showDetails(form, body, picked));
    } catch (e) {
      body.replaceChildren(`Couldn't reach TaskTimer: ${e.message}`);
    }
  }

  function showDetails(form, body, t) {
    const started = t.started_at ? new Date(t.started_at) : null;
    if (!started) {
      body.replaceChildren(el('div', {}, el('b', {}, t.display), el('br'), 'Not started in TaskTimer yet.'));
      return;
    }
    const day = isoDay(started);
    const btn = el('button', { type: 'button', class: 'tt-btn', onclick: () => {
      setValue(form.querySelector('[name=start_date]'), day);
      body.replaceChildren(el('div', { class: 'tt-done' }, `Start Date set to ${day}. Check it, then press Update Task.`));
    } }, 'Fill Start Date');
    body.replaceChildren(el('div', {}, el('b', {}, t.display), el('br'), `Started in TaskTimer on ${day}`), el('div', { class: 'tt-row' }, btn));
  }

  // ───────────── Watch the page ─────────────

  function scan() {
    for (const f of document.querySelectorAll('form#add_members')) {
      if (f.dataset.tt) continue;
      if (!f.querySelector('[name=actual_spent_hours]')) continue;
      f.dataset.tt = '1';
      decorateLogTime(f);
    }
    for (const f of document.querySelectorAll('form#updaterequest')) {
      if (f.dataset.tt) continue;
      f.dataset.tt = '1';
      decorateDetails(f);
    }
  }

  new MutationObserver(() => scan()).observe(document.documentElement, { childList: true, subtree: true });
  scan();

  if (location.pathname.startsWith('/tasks')) {
    syncModhesh();
    setInterval(syncModhesh, 3 * 60 * 1000);
    document.addEventListener('visibilitychange', () => { if (!document.hidden) syncModhesh(); });
  }
})();
