/**
 * TaskTimer → Google Sheet bridge  (script version 2)
 * ---------------------------------------------------
 * Paste this whole file into the team sheet: Extensions › Apps Script.
 * Then Deploy › New deployment › Web app
 *   Execute as: Me      Who has access: Anyone
 * Copy the /exec URL into TaskTimer › Settings › Sheet.
 *
 * TaskTimer reads everything else from the sheet itself (tabs, column titles,
 * and the Account / Status / Team Member dropdowns), so renaming an account,
 * adding a status or starting a new month tab needs no change here and no
 * new deployment — just press "Sync from Sheet" in TaskTimer.
 *
 * The script only writes the six columns below into a new row (or updates
 * the row TaskTimer logged before). It never touches other columns.
 * Older TaskTimer versions keep working with this script.
 */

const CONFIG = {
  // Must match "Secret token" in TaskTimer settings. Change it to anything you like.
  TOKEN: 'CHANGE-ME',

  // Only used by older TaskTimer versions (newer ones pick the tab themselves).
  // Leave '' to use the first tab.
  SHEET_NAME: '',

  // Row that holds the column titles.
  HEADER_ROW: 1,

  // Leave '' to auto-detect from the header titles, or force a column letter, e.g. task: 'B'.
  COLUMNS: { task: '', date: '', client: '', member: '', status: '', time: '' },

  // Date format written in the Date column ('' = write a real date and keep the sheet's own format).
  DATE_FORMAT: '',
};

const SCRIPT_VERSION = 2;

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

// Month names for picking the current month's tab automatically.
const MONTHS = [
  ['january', 'jan', 'يناير'], ['february', 'feb', 'فبراير'], ['march', 'mar', 'مارس'],
  ['april', 'apr', 'ابريل'], ['may', 'مايو'], ['june', 'jun', 'يونيو'],
  ['july', 'jul', 'يوليو'], ['august', 'aug', 'اغسطس'], ['september', 'sep', 'sept', 'سبتمبر'],
  ['october', 'oct', 'اكتوبر'], ['november', 'nov', 'نوفمبر'], ['december', 'dec', 'ديسمبر'],
];

function doPost(e) {
  try {
    const body = JSON.parse((e && e.postData && e.postData.contents) || '{}');
    if (String(body.token || '') !== String(CONFIG.TOKEN)) {
      return reply({ ok: false, error: 'Wrong token. Make TaskTimer’s token match CONFIG.TOKEN in the script.' });
    }
    if (body.action === 'config') {
      return reply(getConfig(body));
    }
    const sheet = resolveSheet(body);
    const cols = detectColumns(sheet);

    if (body.action === 'ping') {
      return reply({ ok: true, version: SCRIPT_VERSION, sheet: sheet.getName(), columns: lettersOf(cols) });
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
  return reply({ ok: true, version: SCRIPT_VERSION, message: 'TaskTimer bridge is running. Use POST.' });
}

// MARK: - Config (everything TaskTimer reads from the sheet)

function getConfig(b) {
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  const tabs = ss.getSheets().map(s => ({ name: s.getName(), hidden: s.isSheetHidden() }));
  const auto = autoSheet(ss, b.date);

  let sheet;
  let warning = '';
  try {
    sheet = resolveSheet(b);
  } catch (err) {
    sheet = auto;
    warning = String(err && err.message || err);
  }

  const cols = detectColumns(sheet);
  const headerRow = sheet.getRange(CONFIG.HEADER_ROW, 1, 1, Math.max(1, sheet.getLastColumn())).getValues()[0];
  const headers = {};
  Object.keys(cols).forEach(k => { headers[k] = String(headerRow[cols[k] - 1] || ''); });

  return {
    ok: true,
    version: SCRIPT_VERSION,
    spreadsheet: ss.getName(),
    tabs: tabs,
    autoTab: auto.getName(),
    sheet: sheet.getName(),
    columns: lettersOf(cols),
    headers: headers,
    lists: {
      client: listFor(sheet, cols.client),
      status: listFor(sheet, cols.status),
      member: listFor(sheet, cols.member),
    },
    timeFormat: timeFormatOf(sheet, cols.time),
    warning: warning,
  };
}

/** The dropdown options of a column, or the values already typed in it if it has no dropdown. */
function listFor(sheet, col) {
  if (!col) return [];
  const first = CONFIG.HEADER_ROW + 1;
  const n = Math.max(1, Math.min(sheet.getMaxRows() - CONFIG.HEADER_ROW, 400));
  const range = sheet.getRange(first, col, n, 1);

  const rules = range.getDataValidations();
  for (let i = 0; i < rules.length; i++) {
    const dv = rules[i][0];
    if (!dv) continue;
    const type = dv.getCriteriaType();
    const vals = dv.getCriteriaValues();
    if (type === SpreadsheetApp.DataValidationCriteria.VALUE_IN_LIST) {
      return clean(vals[0] || []);
    }
    if (type === SpreadsheetApp.DataValidationCriteria.VALUE_IN_RANGE && vals[0]) {
      return clean([].concat.apply([], vals[0].getValues()));
    }
  }
  return clean([].concat.apply([], range.getDisplayValues()));
}

function clean(arr) {
  const seen = {};
  const out = [];
  arr.forEach(v => {
    const s = String(v == null ? '' : v).trim();
    const key = s.toLowerCase();
    if (s && !seen[key]) { seen[key] = true; out.push(s); }
  });
  return out;
}

/** How the time column is written: 'decimal' (2.5), 'minutes' (150) or 'hm' (2:30). '' if unknown. */
function timeFormatOf(sheet, col) {
  if (!col) return '';
  const last = sheet.getLastRow();
  if (last <= CONFIG.HEADER_ROW) return '';
  const n = Math.min(last - CONFIG.HEADER_ROW, 200);
  const vals = sheet.getRange(CONFIG.HEADER_ROW + 1, col, n, 1).getValues().map(r => r[0]);
  let nums = 0, clock = 0, big = 0;
  vals.forEach(v => {
    if (v instanceof Date) { clock++; return; }
    if (typeof v === 'number') { nums++; if (v > 24) big++; return; }
    if (/^\s*\d+:\d{2}\s*$/.test(String(v))) clock++;
  });
  if (nums === 0 && clock === 0) return '';
  if (clock > nums) return 'hm';
  return big > nums / 2 ? 'minutes' : 'decimal';
}

// MARK: - Choosing the tab

function resolveSheet(b) {
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  const mode = String(b.tabMode || '');
  const name = String(b.tab || '').trim();
  if (mode === 'manual' && name) {
    const s = ss.getSheetByName(name);
    if (!s) throw new Error('No tab named "' + name + '". Press Sync from Sheet in TaskTimer and pick the tab again.');
    return s;
  }
  if (mode === 'auto') return autoSheet(ss, b.date);
  return getSheet(); // older TaskTimer versions
}

/** The tab named after the month of `isoDate` (e.g. "Oct 2026", "October", "10-2026", "أكتوبر"),
 *  otherwise the last visible tab that has a task column. */
function autoSheet(ss, isoDate) {
  const d = parseDate(isoDate);
  const month = d.getMonth();
  const year = d.getFullYear();
  const visible = ss.getSheets().filter(s => !s.isSheetHidden());

  let best = null;
  let bestScore = 0;
  visible.forEach(s => {
    const score = monthScore(s.getName(), month, year);
    if (score >= bestScore && score > 0) { best = s; bestScore = score; } // later tabs win ties
  });
  if (best) return best;

  for (let i = visible.length - 1; i >= 0; i--) {
    if (detectColumns(visible[i]).task) return visible[i];
  }
  return visible[visible.length - 1] || ss.getSheets()[0];
}

/** 0 = not this month, 2 = this month (no year in the name), 3 = this month and year. */
function monthScore(name, month, year) {
  const n = normalize(name)
    .replace(/(\p{L})(\p{N})/gu, '$1 $2')
    .replace(/(\p{N})(\p{L})/gu, '$1 $2');
  const words = n.split(' ').filter(Boolean);

  let m = -1;
  MONTHS.forEach((names, i) => {
    if (m < 0 && names.some(x => words.indexOf(normalize(x)) >= 0)) m = i;
  });

  let y = -1;
  const nums = words.filter(w => /^\d+$/.test(w)).map(Number);
  nums.forEach(x => {
    if (x >= 2000 && x <= 2100) y = x;
  });
  if (m < 0) {
    // numeric month next to a year: "10-2026", "2026-10", "10/26"
    for (let i = 0; i < nums.length && m < 0; i++) {
      const a = nums[i], b2 = nums[i + 1];
      if (b2 === undefined) break;
      if (a >= 1 && a <= 12 && (b2 >= 2000 || (b2 >= 20 && b2 <= 99))) { m = a - 1; if (b2 < 100) y = 2000 + b2; }
      else if (a >= 2000 && b2 >= 1 && b2 <= 12) { m = b2 - 1; y = a; }
    }
  } else if (y < 0) {
    const two = nums.filter(x => x >= 20 && x <= 99);
    if (two.length === 1) y = 2000 + two[0]; // "Oct 26"
  }

  if (m !== month) return 0;
  if (y < 0) return 2;
  return y === year ? 3 : 0;
}

function parseDate(s) {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(s || ''));
  if (!m) return new Date();
  return new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3]));
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

// MARK: - Writing a row

function logRow(sheet, cols, b) {
  const missing = DETECT_ORDER.filter(k => !cols[k]);
  if (missing.length === DETECT_ORDER.length) {
    throw new Error('Could not find any matching column titles in row ' + CONFIG.HEADER_ROW + ' of "' + sheet.getName() + '". Set CONFIG.COLUMNS by hand.');
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

    let time = b.time || '';
    if (/^\d+(\.\d+)?$/.test(String(time))) time = Number(time); // 2.5 / 150 → a real number

    const values = {
      task: b.task || '',
      date: parseDate(b.date),
      client: b.client || '',
      member: b.member || '',
      status: b.status || '',
      time: time,
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
    return { ok: true, row: row, updated: updated, missing: missing, tab: sheet.getName(), version: SCRIPT_VERSION };
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

// MARK: - Columns

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
