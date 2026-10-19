/**
 * TaskTimer → Google Sheet bridge
 * --------------------------------
 * Paste this whole file into the team sheet: Extensions › Apps Script.
 * Then Deploy › New deployment › Web app
 *   Execute as: Me      Who has access: Anyone
 * Copy the /exec URL into TaskTimer › Settings › Sheet.
 *
 * The script only writes the six columns below into a new row (or updates
 * the row TaskTimer logged before). It never touches other columns.
 */

const CONFIG = {
  // Must match "Secret token" in TaskTimer settings. Change it to anything you like.
  TOKEN: 'CHANGE-ME',

  // Tab name. Leave '' to use the first tab.
  SHEET_NAME: '',

  // Row that holds the column titles.
  HEADER_ROW: 1,

  // Leave '' to auto-detect from the header titles, or force a column letter, e.g. task: 'B'.
  COLUMNS: { task: '', date: '', client: '', member: '', status: '', time: '' },

  // Date format written in the Date column ('' = write a real date and keep the sheet's own format).
  DATE_FORMAT: '',
};

// Header words used for auto-detection (English + Arabic). First match wins.
const KEYWORDS = {
  task:   ['task', 'تاسك', 'التاسك', 'المهمة', 'مهمة', 'project', 'بروجكت', 'job'],
  client: ['client', 'account', 'brand', 'كلاينت', 'الكلاينت', 'اكونت', 'أكونت', 'العميل', 'عميل'],
  status: ['status', 'state', 'ستاتس', 'الحالة', 'حالة'],
  date:   ['date', 'day', 'تاريخ', 'التاريخ'],
  time:   ['time', 'hours', 'hrs', 'duration', 'spent', 'وقت', 'الوقت', 'ساعات', 'المدة', 'مدة'],
  member: ['member', 'name', 'designer', 'animator', 'assignee', 'by', 'team', 'الاسم', 'اسم', 'الموظف', 'المصمم', 'العضو', 'عضو'],
};
// Detection order matters: "Task Name" must become task, "Account Name" client, plain "Name" member.
const DETECT_ORDER = ['task', 'client', 'status', 'date', 'time', 'member'];

function doPost(e) {
  try {
    const body = JSON.parse((e && e.postData && e.postData.contents) || '{}');
    if (String(body.token || '') !== String(CONFIG.TOKEN)) {
      return reply({ ok: false, error: 'Wrong token. Make TaskTimer’s token match CONFIG.TOKEN in the script.' });
    }
    const sheet = getSheet();
    const cols = detectColumns(sheet);

    if (body.action === 'ping') {
      return reply({ ok: true, sheet: sheet.getName(), columns: lettersOf(cols) });
    }
    if (body.action === 'log') {
      return reply(logRow(sheet, cols, body));
    }
    return reply({ ok: false, error: 'Unknown action.' });
  } catch (err) {
    return reply({ ok: false, error: String(err && err.message || err) });
  }
}

function doGet() {
  return reply({ ok: true, message: 'TaskTimer bridge is running. Use POST.' });
}

function logRow(sheet, cols, b) {
  const missing = DETECT_ORDER.filter(k => !cols[k]);
  if (missing.length === DETECT_ORDER.length) {
    throw new Error('Could not find any matching column titles in row ' + CONFIG.HEADER_ROW + '. Set CONFIG.COLUMNS by hand.');
  }

  const lock = LockService.getScriptLock();
  lock.waitLock(20000);
  try {
    let row = null;
    let updated = false;

    // Update the earlier row only if it still holds the same task.
    const want = Number(b.updateRow);
    if (want && want > CONFIG.HEADER_ROW && want <= sheet.getMaxRows() && cols.task) {
      const existing = String(sheet.getRange(want, cols.task).getValue()).trim();
      if (existing.toLowerCase() === String(b.task || '').trim().toLowerCase()) {
        row = want;
        updated = true;
      }
    }
    if (!row) row = nextEmptyRow(sheet, cols);

    const values = {
      task: b.task || '',
      date: toDate(b.date),
      client: b.client || '',
      member: b.member || '',
      status: b.status || '',
      time: b.time || '',
    };
    Object.keys(values).forEach(k => {
      if (!cols[k]) return;
      const cell = sheet.getRange(row, cols[k]);
      let v = values[k];
      if (k === 'date' && CONFIG.DATE_FORMAT && v instanceof Date) {
        v = Utilities.formatDate(v, Session.getScriptTimeZone(), CONFIG.DATE_FORMAT);
      }
      cell.setValue(v);
    });
    SpreadsheetApp.flush();
    return { ok: true, row: row, updated: updated, missing: missing };
  } finally {
    lock.releaseLock();
  }
}

/** First row after the last row that has a task name (ignores pre-filled formulas/checkboxes in other columns). */
function nextEmptyRow(sheet, cols) {
  const keyCol = cols.task || cols.date || cols.client;
  const last = sheet.getLastRow();
  if (last <= CONFIG.HEADER_ROW) return CONFIG.HEADER_ROW + 1;
  const vals = sheet.getRange(CONFIG.HEADER_ROW + 1, keyCol, last - CONFIG.HEADER_ROW, 1).getValues();
  for (let i = vals.length - 1; i >= 0; i--) {
    if (String(vals[i][0]).trim() !== '') return CONFIG.HEADER_ROW + 2 + i;
  }
  return CONFIG.HEADER_ROW + 1;
}

function getSheet() {
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  if (CONFIG.SHEET_NAME) {
    const s = ss.getSheetByName(CONFIG.SHEET_NAME);
    if (!s) throw new Error('No tab named "' + CONFIG.SHEET_NAME + '".');
    return s;
  }
  return ss.getSheets()[0];
}

function detectColumns(sheet) {
  const cols = {};
  const lastCol = Math.max(1, sheet.getLastColumn());
  const headers = sheet.getRange(CONFIG.HEADER_ROW, 1, 1, lastCol).getValues()[0]
    .map(h => normalize(h));
  const used = new Set();

  DETECT_ORDER.forEach(key => {
    const forced = CONFIG.COLUMNS[key];
    if (forced) {
      cols[key] = letterToIndex(forced);
      used.add(cols[key]);
    }
  });

  DETECT_ORDER.forEach(key => {
    if (cols[key]) return;
    for (const kw of KEYWORDS[key]) {
      const k = normalize(kw);
      const idx = headers.findIndex((h, i) => !used.has(i + 1) && h && hasWord(h, k));
      if (idx >= 0) {
        cols[key] = idx + 1;
        used.add(idx + 1);
        return;
      }
    }
  });
  return cols;
}

function normalize(s) {
  return String(s || '').toLowerCase()
    .replace(/[أإآ]/g, 'ا').replace(/ة/g, 'ه').replace(/ى/g, 'ي')
    .replace(/[^\p{L}\p{N}]+/gu, ' ').trim();
}

function hasWord(header, kw) {
  if (kw.includes(' ')) return header.includes(kw);
  const words = header.split(' ');
  return words.includes(kw) || words.some(w => w.startsWith(kw) && kw.length >= 4);
}

function toDate(s) {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(s || ''));
  if (!m) return new Date();
  return new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3]));
}

function letterToIndex(letter) {
  let n = 0;
  String(letter).toUpperCase().replace(/[^A-Z]/g, '').split('').forEach(c => { n = n * 26 + (c.charCodeAt(0) - 64); });
  return n;
}

function indexToLetter(i) {
  let s = '';
  while (i > 0) { const m = (i - 1) % 26; s = String.fromCharCode(65 + m) + s; i = Math.floor((i - 1) / 26); }
  return s;
}

function lettersOf(cols) {
  const out = {};
  Object.keys(cols).forEach(k => { out[k] = indexToLetter(cols[k]); });
  return out;
}

function reply(obj) {
  return ContentService.createTextOutput(JSON.stringify(obj)).setMimeType(ContentService.MimeType.JSON);
}
