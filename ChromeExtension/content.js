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

  /// Waits for a link made in the TaskTimer app while this form is open.
  function watchForLink(form, code, onLinked) {
    const timer = setInterval(async () => {
      if (!document.contains(form)) return clearInterval(timer);
      try {
        const row = await modheshRow(code);
        if (row && row.task_id) {
          const t = (await myTasks(true)).find((x) => x.id === row.task_id);
          if (t) { clearInterval(timer); onLinked(t, row); }
        }
      } catch (e) { /* try again */ }
    }, 3000);
  }

  async function chooser(body, code, title, onPick) {
    const tasks = await myTasks(true);
    if (!tasks.length) {
      const s = await TT.session();
      body.replaceChildren(
        `No TaskTimer tasks found for ${(s && s.email) || 'this account'}. ` +
        'Sign in to the TaskTimer app (Settings → Team) with the same account — your tasks appear here a few seconds later.');
      return;
    }
    const ranked = tasks
      .map((t) => ({ t, score: similarity(title, t.display) }))
      .sort((a, b) => b.score - a.score || new Date(b.t.created_at) - new Date(a.t.created_at));
    // Amends (subtasks) show as "Task - Amend 1"; they can be linked like any task.
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

  /// "No Challenges at all" is the default answer, unless something else is ticked.
  async function defaultChallenge(form, value) {
    const boxes = [...form.querySelectorAll('[name="task_challenge[]"]')];
    if (!boxes.length || boxes.some((c) => c.checked)) return;
    let v = value;
    if (!v) {
      try { v = (await TT.settings()).challenge; } catch (e) { v = 1; }
    }
    const box = boxes.find((c) => c.value === String(v || 1)) || boxes.find((c) => c.value === '1');
    if (box) box.click();
  }

  async function decorateLogTime(form) {
    const code = (form.querySelector('[name=task_id]') || {}).value;
    if (!code) return;
    defaultChallenge(form);
    const body = bar(form, 'log');
    if (!(await TT.session())) return signedOut(body);
    const title = (document.querySelector(`[data-post-task_id="${CSS.escape(code)}"]`) || {}).textContent?.trim() || '';
    try {
      const row = await modheshRow(code);
      const tasks = await myTasks(true);
      const linked = row && row.task_id && tasks.find((t) => t.id === row.task_id);
      if (linked) showLogTime(form, body, linked, row);
      else {
        await chooser(body, code, (row && row.title) || title, async (t) => showLogTime(form, body, t, await modheshRow(code)));
        watchForLink(form, code, (t, r) => showLogTime(form, body, t, r));
      }
    } catch (e) {
      body.replaceChildren(`Couldn't reach TaskTimer: ${e.message}`);
    }
  }

  async function showLogTime(form, body, t, row) {
    const total = liveSeconds(t);
    const logged = (row && Number(row.logged_seconds)) || 0;
    const toLog = Math.max(0, total - logged);
    const st = await TT.settings().catch(() => ({}));
    const deliverables = t.deliverables ?? st.default_deliverables ?? 1;
    const rating = t.rating ?? st.default_rating ?? 5;
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

    await defaultChallenge(form, v.challenge);

    let approverNote = '';
    let approver = '';
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
          approver = opt.textContent.trim();
        } else {
          approverNote = ` · Couldn't find ${leader.full_name || 'your leader'} in the Approver list — pick them`;
        }
      } else if (select) {
        approverNote = ' · No team leader found in TaskTimer — pick the approver';
      }
    }
    if (body) {
      body.replaceChildren(el('div', { class: 'tt-done' },
        `Filled ✓ ${Math.floor(mins / 60)}h ${mins % 60}m${approverNote}. Check it, then press Save.`));
    }
    return { mins, approver, approverNote };
  }

  // ───────────── Logging by itself (jobs from the background worker) ─────────────

  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const visible = (e) => !!(e && (e.offsetWidth || e.offsetHeight || e.getClientRects().length));

  async function waitFor(fn, ms = 15000) {
    const end = Date.now() + ms;
    while (Date.now() < end) {
      const v = fn();
      if (v) return v;
      await sleep(300);
    }
    return null;
  }

  function closeModal() {
    const m = document.getElementById('ajaxmodel');
    const x = m && m.querySelector('[data-bs-dismiss=modal], .btn-close, .close');
    if (x) x.click();
  }

  function pageError() {
    const sel = '.swal2-html-container, .swal2-title, .toast-error .toast-message, .invalid-feedback, #ajaxmodel .text-danger, #ajaxmodel .alert-danger';
    const e = [...document.querySelectorAll(sel)].find((x) => visible(x) && x.textContent.trim());
    return e ? e.textContent.trim().slice(0, 160) : '';
  }

  /// Pending to Start → In Progress, through Task Details. Sets only the status and the
  /// Start Date (from TaskTimer); Estimate and the deliverables link are left as they are.
  async function startInModhesh(job) {
    const open = document.querySelector(`[data-act="drawer-modal"][data-post-task_id="${CSS.escape(job.code)}"]`);
    if (!open) throw new Error('Task not found on the Modhesh board');
    open.click();
    const form = await waitFor(() => {
      const f = document.querySelector('form#updaterequest');
      return f && (f.querySelector('[name=task_id]') || {}).value === job.code && f.querySelector('[name=status]') ? f : null;
    }, 20000);
    if (!form) throw new Error('Task Details didn\'t open, or the task can\'t be edited');
    await sleep(600);

    const status = form.querySelector('[name=status]');
    const opt = [...status.options].find((o) => /in\s*progress/i.test(o.textContent));
    if (!opt) throw new Error('Modhesh has no "In Progress" status for this task');
    status.value = opt.value;
    status.dispatchEvent(new Event('change', { bubbles: true }));

    const start = form.querySelector('[name=start_date]');
    if (start) setValue(start, isoDay(job.startedAt ? new Date(job.startedAt) : new Date()));
    await sleep(400);

    const save = [...document.querySelectorAll('button, input[type=submit]')]
      .find((b) => visible(b) && /update\s*task/i.test(b.textContent || b.value || ''));
    if (!save) throw new Error('Update Task button not found');
    save.click();

    const result = await waitFor(() => {
      const err = pageError();
      if (err) return { err };
      if (!document.contains(form) || !visible(form)) return { ok: true };
      return null;
    }, 20000);
    if (!result || result.err) {
      throw new Error((result && result.err) || 'Modhesh didn\'t confirm the status change');
    }
    const x = [...document.querySelectorAll('.btn-close, [data-kt-drawer-dismiss], [data-bs-dismiss]')].find(visible);
    if (x) x.click();
  }

  async function submitLogTime(job) {
    const btn = await waitFor(() =>
      document.querySelector(`[data-action-url$="/tasks/log-time"][data-post-task_id="${CSS.escape(job.code)}"]`), 25000);
    if (!btn) throw new Error('It isn\'t In Progress on Modhesh (no Log Time button)');
    btn.click();
    const form = await waitFor(() => {
      const f = document.querySelector('form#add_members');
      return f && (f.querySelector('[name=task_id]') || {}).value === job.code ? f : null;
    });
    if (!form) throw new Error('Log Time didn\'t open');
    await sleep(500);

    const r = await fillLogTime(form, null, job);
    if (!r.approver) {
      closeModal();
      throw new Error(r.approverNote.replace(/^ · /, '') || 'No approver');
    }
    if (r.mins < 1) {
      closeModal();
      throw new Error('Nothing to log');
    }
    await sleep(400);

    const modal = document.getElementById('ajaxmodel');
    const save = [...modal.querySelectorAll('button, input[type=submit]')]
      .find((b) => /^\s*save\s*$/i.test(b.textContent || b.value || '')) || form.querySelector('[type=submit]');
    if (!save) {
      closeModal();
      throw new Error('Save button not found');
    }
    save.click();

    // Success: the window closes (or the form is replaced). Failure: an error message shows.
    const result = await waitFor(() => {
      const err = pageError();
      if (err) return { err };
      if (!document.contains(form) || !modal.classList.contains('show')) return { ok: true };
      return null;
    }, 20000);
    if (!result || result.err) {
      const why = (result && result.err) || 'Modhesh didn\'t confirm';
      closeModal();
      throw new Error(why);
    }
    return `Logged ${Math.floor(r.mins / 60)}h ${r.mins % 60}m · approver ${r.approver}`;
  }

  let jobsRunning = false;
  async function runJobs(jobs) {
    if (jobsRunning) return;
    if (!jobs || !jobs.length) { chrome.runtime.sendMessage({ type: 'allDone' }).catch(() => {}); return; }
    jobsRunning = true;
    try {
      let reload = false;
      for (const job of jobs) {
        let ok = false, note = '';
        try {
          const logBtn = () => document.querySelector(`[data-action-url$="/tasks/log-time"][data-post-task_id="${CSS.escape(job.code)}"]`);
          await waitFor(() => logBtn() || document.querySelector(`[data-post-task_id="${CSS.escape(job.code)}"]`), 20000);
          if (!logBtn()) {
            await startInModhesh(job);
            if (!(await waitFor(logBtn, 15000))) {
              // The board didn't refresh by itself: reload and log right after.
              await chrome.runtime.sendMessage({ type: 'jobRetry', job }).catch(() => {});
              reload = true;
              continue;
            }
          }
          note = await submitLogTime(job);
          ok = true;
        } catch (e) {
          note = e.message;
        }
        log(ok ? 'logged' : 'failed', job.code, note);
        await chrome.runtime.sendMessage({ type: 'jobDone', job, ok, note }).catch(() => {});
        await sleep(1500);
      }
      if (reload) {
        setTimeout(() => location.reload(), 1500);
        return;
      }
    } finally {
      jobsRunning = false;
    }
    chrome.runtime.sendMessage({ type: 'allDone' }).catch(() => {});
  }

  chrome.runtime.onMessage.addListener((msg) => {
    if (msg.type === 'jobs') runJobs(msg.jobs);
  });

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
      else {
        await chooser(body, code, title, async (picked) => showDetails(form, body, picked));
        watchForLink(form, code, (picked) => showDetails(form, body, picked));
      }
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

  // ───────────── Badges on the board ─────────────
  // Each Modhesh card that is linked shows its TaskTimer task and hours, refreshed every few
  // seconds — so a link made in the app shows up here right away.

  let badgeBusy = false;
  async function decorateBoard() {
    if (badgeBusy || !document.querySelector('.kanban-card')) return;
    if (!(await TT.session())) return;
    badgeBusy = true;
    try {
      const uid = await TT.userId();
      const rows = await TT.rest('GET', `modhesh_tasks?user_id=eq.${uid}&task_id=not.is.null&select=code,task_id`);
      const tasks = await myTasks(true);
      const byId = Object.fromEntries(tasks.map((t) => [t.id, t]));
      const byCode = Object.fromEntries(rows.map((r) => [r.code, byId[r.task_id]]));
      for (const card of document.querySelectorAll('.kanban-card')) {
        const link = card.querySelector('[data-post-task_id]');
        const code = link && link.getAttribute('data-post-task_id');
        const t = code && byCode[code];
        let badge = card.querySelector('.tt-badge');
        if (!t) { if (badge) badge.remove(); continue; }
        if (!badge) {
          badge = el('div', { class: 'tt-badge' });
          (card.querySelector('.card-body') || card).append(badge);
        }
        const running = t.running_since ? ' · ⏺ running' : '';
        const text = `⏱ TaskTimer: ${t.display} · ${hours(liveSeconds(t))} h${running}`;
        if (badge.textContent !== text) badge.textContent = text;
      }
    } catch (e) {
      log('badges failed:', e.message);
    } finally {
      badgeBusy = false;
    }
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

  if (location.pathname.startsWith('/tasks/my')) {
    // Anything to log by itself? (the background worker may have opened this tab for it)
    setTimeout(() => {
      chrome.runtime.sendMessage({ type: 'getJobs' }).then((r) => runJobs(r && r.jobs)).catch(() => {});
    }, 2500);
  }

  if (location.pathname.startsWith('/tasks')) {
    let badgeTimer = null;
    const ours = (n) => n && n.nodeType === 1 && (n.classList.contains('tt-badge') || n.closest('.tt-badge, .tt-bar'));
    new MutationObserver((list) => {
      // Ignore changes we made ourselves (badges), or this would run in a loop.
      if (list.every((m) => ours(m.target) || [...m.addedNodes, ...m.removedNodes].every(ours))) return;
      clearTimeout(badgeTimer);
      badgeTimer = setTimeout(decorateBoard, 600);
    }).observe(document.documentElement, { childList: true, subtree: true });
    setInterval(() => { if (!document.hidden) decorateBoard(); }, 5000);
    syncModhesh();
    setInterval(syncModhesh, 3 * 60 * 1000);
    document.addEventListener('visibilitychange', () => { if (!document.hidden) syncModhesh(); });
  }
})();
