'use strict';
// True on the web: a thin window onto panes the Mac already has open. The Mac stays authoritative:
// this page never resizes a PTY, it renders at the Mac's cols and scales/scrolls to fit.
const $ = (id) => document.getElementById(id);
const enc = new TextEncoder();
const KEYS = { enter: '\r', esc: '\x1b', tab: '\t', up: '\x1b[A', down: '\x1b[B', right: '\x1b[C', left: '\x1b[D', cc: '\x03' };

// Pairing token: localStorage + Authorization header, never a cookie (cookies ignore ports and would also reach
// other services on the same *.ts.net hostname).
const TOKEN_KEY = 'true.token';
const getToken = () => localStorage.getItem(TOKEN_KEY);
function api(path) { return fetch(path, { cache: 'no-store', headers: { Authorization: 'Bearer ' + getToken() } }); }
function unpair() {
  localStorage.removeItem(TOKEN_KEY); view = 'pair'; paneId = null;
  clearTimeout(retryTimer); if (ws) { ws.onclose = null; ws.close(); ws = null; }
  for (const id of ['list', 'termlist', 'term', 'shots', 'send', 'viewer', 'sheet']) $(id).hidden = true;
  document.documentElement.classList.remove('inpane');
  $('term').className = ''; $('nav').hidden = true; document.body.classList.remove('hasnav', 'scrolled'); $('pair').hidden = false; banner(''); paintCode();
}

let view = 'list', paneId = null, term = null, ws = null, cols = 80, rows = 24;
let fit = true, ctrl = false, retry = 0, retryTimer = null, listFails = 0, wsEverOpen = false;

// Floating pill at the top. Warnings carry the accent dot; success toasts (ok) a neutral one and are not cleared by polling for ~3 s.
let okUntil = 0;
function banner(msg, ok) {
  const t = $('toast');
  if (!msg) { if (Date.now() < okUntil) return; t.classList.remove('show'); return; }
  if (!ok && Date.now() < okUntil) return;   // a warning never replaces a fresh confirmation toast
  okUntil = ok ? Date.now() + 2900 : 0;
  $('toastText').textContent = msg; t.classList.toggle('ok', !!ok); placeToast(); t.classList.add('show');
}
// In a pane the toast sits just above the key strip/composer (and so above the keyboard); elsewhere it stays at the top.
function placeToast() {
  const t = $('toast'), inPane = view === 'term' && !$('term').hidden;
  t.classList.toggle('inpane', inPane);
  t.style.top = inPane ? ($('keys').getBoundingClientRect().top - 8) + 'px' : '';
}

const ICON = {
  chev: '<svg viewBox="0 0 24 24" width="16" height="16" aria-hidden="true"><path d="M9 5l7 7-7 7"/></svg>',
  down: '<svg viewBox="0 0 24 24" width="10" height="10" aria-hidden="true"><path d="M5 9l7 7 7-7"/></svg>',
  check: '<svg viewBox="0 0 24 24" width="20" height="20" aria-hidden="true"><path d="M5 12.5l4.5 4.5L19 7.5"/></svg>',
  x: '<svg viewBox="0 0 24 24" width="12" height="12" aria-hidden="true"><path d="M6 6l12 12M18 6L6 18"/></svg>',
  seat: '<svg viewBox="0 0 24 24" width="20" height="20" aria-hidden="true"><rect x="4" y="4" width="16" height="16" rx="4"/><circle cx="12" cy="10" r="2.6"/><path d="M6.5 18.5c1-2.6 3-3.8 5.5-3.8s4.5 1.2 5.5 3.8"/></svg>',
  wrench: '<svg viewBox="0 0 24 24" width="20" height="20" aria-hidden="true"><path d="M14.5 6.5a4 4 0 005 5l-8.8 8.8a2.1 2.1 0 01-3-3L16.5 8.5M14.5 6.5l3-3 3 3-3 3"/></svg>',
  term: '<svg viewBox="0 0 24 24" width="20" height="20" aria-hidden="true"><path d="M5 8l4 4-4 4M12 17h7"/></svg>',
  doc: '<svg viewBox="0 0 24 24" width="20" height="20" aria-hidden="true"><path d="M7 3.5h6.5L18 8v11.5a1 1 0 01-1 1H7a1 1 0 01-1-1v-15a1 1 0 011-1zM13 3.5V8h5"/></svg>',
  quote: '<svg viewBox="0 0 24 24" width="20" height="20" aria-hidden="true"><path d="M5 7h14M5 12h14M5 17h8"/></svg>',
};
function ic(name) { const t = document.createElement('template'); t.innerHTML = ICON[name]; return t.content.firstChild; }
function glyph(name) { const g = el('span', 'glyph'); g.appendChild(ic(name)); return g; }

// ---------- Hub (the Mac Hub's own model, GET /api/hub) ----------
async function loadList() {
  if (view !== 'list' || document.hidden) return;
  try {
    const r = await api('/api/hub');
    if (r.status === 401) { unpair(); return; }
    if (!r.ok) throw new Error(String(r.status));
    const data = await r.json();
    listFails = 0; banner('');
    renderHub(data);
  } catch (e) {
    if (!hubData) { $('skel').hidden = true; $('empty').hidden = true; const h = $('tabs'); h.textContent = ''; h.appendChild(stateBlock("Can't reach the Mac", 'Check that it is awake and True is open.', () => { listFails = 0; $('skel').hidden = false; h.textContent = ''; loadList(); })); }
    else if (++listFails >= 2) banner('Mac asleep or offline — retrying…');
  }
}

function el(tag, cls, text) { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; }

let hubData = null, sessionsAll = false;
const acking = new Set(), ackedLocal = new Set();   // builder ids: ack in flight (row hidden) / ack confirmed here
const isBuilder = (r) => r.kind === 'background' && r.builderId;
const isAcked = (r) => r.acked || ackedLocal.has(r.builderId);

// The Hub bands. Mirrors the Mac's HubTriage.swift (build/item): needs-you and running are always shown, finished
// work is one row, idle sessions sit last. Plain code on purpose — no model in the loop.
function band(r) {
  const k = r.statusKey;
  if (isBuilder(r)) {
    if (acking.has(r.builderId)) return null;
    const acked = isAcked(r);
    if (k === 'working') return 'running';
    if (k === 'needsYou') return acked ? 'older' : 'needs';          // paused/held: blocked on you, any age
    if (k === 'failed') return acked ? 'older' : r.fresh ? 'needs' : 'older';
    return acked || !r.fresh ? 'older' : 'new';
  }
  if (k === 'needsYou') return 'needs';
  if (k === 'working') return 'running';
  return 'sessions';
}
function ago(secs) {
  const d = Math.max(0, ((hubData && hubData.now) || Date.now() / 1000) - secs);   // Mac clock, not the phone's
  if (d < 90) return 'just now';
  if (d < 3570) return Math.round(d / 60) + 'm ago';
  if (d < 129600) return Math.round(d / 3600) + 'h ago';
  return Math.round(d / 86400) + 'd ago';
}
const rowGlyph = (r) => (r.kind === 'seat' ? 'seat' : r.kind === 'background' ? 'wrench' : 'term');
const isFailedOpen = (r) => r.statusKey === 'failed' && !isAcked(r);

function hubRow(r, project, sub, extra) {
  const live = r.pane || isBuilder(r);
  return listRow(Object.assign({ glyph: rowGlyph(r), name: r.name, sub, subTone: isFailedOpen(r) ? 'bad' : '', chev: !!live, onclick: () => rowTap(r) }, extra));
}
function section(host, title, count, rows) {
  const h = el('h3', 'sec'); h.append(el('span', null, title), el('span', 's', count));
  const g = el('div', 'group'); rows.forEach((x) => g.appendChild(x));
  host.append(h, g);
}
function renderHub(data) {
  hubData = data;
  const host = $('tabs'); host.textContent = '';
  $('skel').hidden = true;
  $('hubSummary').textContent = data.summary || '';
  const B = { needs: [], running: [], sessions: [], new: [], older: [] };
  for (const g of data.projects || []) for (const r of g.rows || []) { const b = band(r); if (b) B[b].push({ r, project: g.title }); }
  const failFirst = (a, b) => (isFailedOpen(b.r) - isFailedOpen(a.r)) || ((b.r.ended || 0) - (a.r.ended || 0));
  B.new.sort((a, b) => (b.r.ended || 0) - (a.r.ended || 0)); B.older.sort(failFirst);
  if (B.needs.length) section(host, 'Needs you', String(B.needs.length), B.needs.map(({ r, project }) => hubRow(r, project, r.question || r.status, { label: project })));
  if (B.running.length) section(host, 'Running', String(B.running.length), B.running.map(({ r, project }) => hubRow(r, project, [project, r.elapsed].filter(Boolean).join(' · '))));
  if (B.sessions.length) {
    const shown = sessionsAll ? B.sessions : B.sessions.slice(0, 5);
    const rows = shown.map(({ r, project }) => hubRow(r, project, [project, r.status].filter(Boolean).join(' · ')));
    if (B.sessions.length > 5) {
      const more = el('button', 'row more'), t = el('span', 't');
      t.appendChild(el('span', 'n', sessionsAll ? 'Show fewer' : 'Show all ' + B.sessions.length));
      more.appendChild(t); more.onclick = () => { sessionsAll = !sessionsAll; renderHub(hubData); };
      rows.push(more);
    }
    section(host, 'Sessions', String(B.sessions.length), rows);
  }
  const nNew = B.new.length, nOld = B.older.length;
  if (nNew + nOld) {
    const fin = listRow({ glyph: 'wrench', name: 'Finished builds', chev: true, chip: { cls: nNew ? 'needsYou' : 'idle', text: nNew ? nNew + ' new' : nOld + ' older' }, onclick: () => openFinished() });
    section(host, 'Finished', '', [fin]);
  }
  $('empty').hidden = host.childNodes.length > 0;
  $('clock').textContent = new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
}
// The Finished sheet: New, then Older (open failures first, in red). Rows open the builder sheet, which holds Ack.
function openFinished() {
  const B = { new: [], older: [] };
  for (const g of hubData.projects || []) for (const r of g.rows || []) { const b = band(r); if (b === 'new' || b === 'older') B[b].push(r); }
  const byEnd = (a, b) => (isFailedOpen(b) - isFailedOpen(a)) || ((b.ended || 0) - (a.ended || 0));
  B.new.sort((a, b) => (b.ended || 0) - (a.ended || 0)); B.older.sort(byEnd);
  openSheet('Finished builds', (body) => {
    for (const [key, title] of [['new', 'New'], ['older', 'Older']]) {
      if (!B[key].length) continue;
      const h = el('h3', 'sec'); h.append(el('span', null, title), el('span', 's', String(B[key].length)));
      const g = el('div', 'group');
      for (const r of B[key]) g.appendChild(listRow({ glyph: 'wrench', name: r.name, sub: [r.status, r.ended ? ago(r.ended) : ''].filter(Boolean).join(' · '), subTone: isFailedOpen(r) ? 'bad' : '', chev: true, onclick: () => openBuilder(r) }));
      body.append(h, g);
    }
  });
}

function rowTap(r) {
  if (r.pane) { openPane(r.pane, r.name); return; }
  if (r.kind === 'background' && r.builderId) { openBuilder(r); return; }
  openSheet(r.name, (body) => {
    body.append(el('p', 'hint', 'Running in another terminal. Read-only here.'),
      el('pre', null, [r.status, r.cwd, r.elapsed].filter(Boolean).join('\n')));
  });
}

// ---------- sheets ----------
let sheetTimer = null;
function openSheet(title, fill, closeLabel) {
  clearTimeout(sheetTimer);
  $('sheetTitle').textContent = title; $('sheetClose').textContent = closeLabel || 'Done';
  const body = $('sheetBody'); body.textContent = '';
  fill(body);
  const sh = $('sheet');
  if (sh.hidden) { sh.hidden = false; void sh.offsetWidth; }
  $('sheetBox').style.transform = ''; sh.classList.add('open');
}
function closeSheet() {
  const sh = $('sheet'); if (sh.hidden) return;
  sh.classList.remove('open'); $('sheetBox').style.transform = '';
  clearTimeout(sheetTimer); sheetTimer = setTimeout(() => { sh.hidden = true; $('sheetBody').textContent = ''; }, 420);
}
$('sheetClose').onclick = closeSheet; $('sheetBack').onclick = closeSheet;
document.addEventListener('keydown', (e) => { if (e.key === 'Escape' && !$('sheet').hidden) closeSheet(); });
(() => { // swipe down on the grabber/header to dismiss; under 80 px it springs back
  const head = $('sheetHead'), box = $('sheetBox'); let y0 = null, dy = 0;
  head.addEventListener('pointerdown', (e) => { if (e.target.closest('button')) return; y0 = e.clientY; dy = 0; head.setPointerCapture(e.pointerId); box.classList.add('drag'); });
  head.addEventListener('pointermove', (e) => { if (y0 === null) return; dy = Math.max(0, e.clientY - y0); box.style.transform = 'translateY(' + dy + 'px)'; });
  const end = () => { if (y0 === null) return; y0 = null; box.classList.remove('drag'); if (dy > 80) closeSheet(); else box.style.transform = ''; };
  head.addEventListener('pointerup', end); head.addEventListener('pointercancel', end);
})();

async function openBuilder(r) {
  openSheet(r.name, (body) => body.appendChild(el('p', 'hint', 'Loading…')));
  try {
    const resp = await api('/api/hub/builder/' + encodeURIComponent(r.builderId));
    if (resp.status === 401) { unpair(); return; }
    if (!resp.ok) throw new Error(String(resp.status));
    const d = await resp.json();
    openSheet(d.name || r.name, (body) => {
      body.append(el('p', 'hint', d.status + (d.acked ? ' · acknowledged' : '')), el('pre', null, d.text || '(no result text yet)'));
      if (d.canAck && !d.acked) {
        const ack = el('button', 'primary', 'Ack');
        ack.onclick = async () => {
          const id = r.builderId;
          acking.add(id); closeSheet(); if (hubData) renderHub(hubData);   // the row leaves at once
          try {
            const x = await api2('/api/hub/builder/' + encodeURIComponent(id) + '/ack', 'POST', '{}', { 'Content-Type': 'application/json' });
            if (x.ok || x.status === 404) ackedLocal.add(id); else { toast("Couldn't clear"); }   // 404 = already gone
          } catch (e) { toast("Couldn't clear"); }
          acking.delete(id); if (hubData) renderHub(hubData); loadList();
        };
        body.appendChild(ack);
      }
    });
  } catch (e) { openSheet(r.name, (body) => body.appendChild(el('p', 'msg', 'Could not load (Mac offline?)'))); }
}

// ---------- ⌘K on the phone: the server proposes, the phone only picks from its lists ----------
const SLOT_NAMES = { kind: 'Kind', project: 'Project', target: 'Where', model: 'Model', effort: 'Effort' };
let cur = null;   // { routeId, route, candidates }

$('fab').onclick = openComposer;
async function openComposer() {
  cur = null;
  openSheet('Start work', (body) => {
    const t = el('textarea', 'field'); t.id = 'cmdText'; t.rows = 4; t.maxLength = 4000; t.placeholder = 'What should happen?';
    t.style.minHeight = '96px'; t.setAttribute('aria-label', 'Command');
    const go = el('button', 'primary', 'Route'); go.id = 'cmdRoute';
    const out = el('div'); out.id = 'cmdOut';
    const rec = el('div', 'recent'); rec.id = 'cmdRecent';
    // One line only: a line break would act as Enter in a shell, so it is never sent.
    t.addEventListener('keydown', (ev) => { if (ev.key === 'Enter') { ev.preventDefault(); go.click(); } });
    t.addEventListener('input', () => { if (/[\r\n]/.test(t.value)) t.value = t.value.replace(/[\r\n]+/g, ' '); });
    go.onclick = () => routeIt(t.value.replace(/[\r\n]+/g, ' '));
    body.append(t, go, out, rec);
    t.focus(); loadRecent(t);
  }, 'Cancel');
}

async function loadRecent(t) {
  try {
    const r = await api('/api/recent'); if (!r.ok) return;
    const d = await r.json(); const host = $('cmdRecent'); if (!host || !(d.items || []).length) return;
    host.appendChild(el('h3', 'sec', 'Recent'));
    const grp = el('div', 'group');
    for (const s of d.items.slice(0, 12)) { const b = el('button', null, s); b.onclick = () => { t.value = s; t.focus(); }; grp.appendChild(b); }
    host.appendChild(grp);
  } catch (e) { /* history is optional */ }
}

async function routeIt(text) {
  const out = $('cmdOut'); out.textContent = '';
  if (!text.trim()) return;
  $('cmdRoute').classList.remove('alt');
  out.appendChild(el('p', 'hint', 'Routing…'));
  try {
    const r = await api2('/api/route', 'POST', JSON.stringify({ text }), { 'Content-Type': 'application/json' });
    if (r.status === 401) { unpair(); return; }
    if (r.status === 429) { out.textContent = ''; out.appendChild(el('p', 'msg', 'Slow down — too many requests.')); return; }
    if (!r.ok) throw new Error(String(r.status));
    cur = await r.json(); renderRoute();
  } catch (e) { out.textContent = ''; out.appendChild(el('p', 'msg', 'Could not route (Mac offline?)')); }
}

function slotValues(r) { return { kind: r.kindLabel, project: r.project || '—', target: r.where, model: r.model || 'default', effort: r.effort || 'default' }; }
function renderRoute(note) {
  const out = $('cmdOut'); out.textContent = '';
  const r = cur.route;
  // One primary per screen: once a route is up, Run is the call and Route becomes the quiet re-do.
  $('cmdRoute').classList.add('alt');
  const chips = el('div', 'chips');
  const vals = slotValues(r);
  for (const s of Object.keys(SLOT_NAMES)) {
    if (!(cur.candidates && cur.candidates[s] && cur.candidates[s].length)) continue;
    const c = el('button', 'rc' + (r.uncertain && r.uncertain.includes(s) ? ' unsure' : '') + (s === 'kind' && r.dangerous ? ' danger' : ''));
    c.append(el('small', null, SLOT_NAMES[s]), el('b', null, vals[s]), ic('down'));
    c.setAttribute('aria-label', SLOT_NAMES[s] + ': ' + vals[s]);
    c.onclick = () => pickSlot(s);
    chips.appendChild(c);
  }
  out.appendChild(chips);
  if (note) out.appendChild(el('p', 'msg', note));
  if (r.twoChoice) out.appendChild(el('p', 'hint', 'Not sure what this is — pick a kind above.'));
  if (r.dangerous) out.appendChild(el('p', 'msg', 'Looks risky — you will be asked to confirm.'));
  const tog = el('label', 'sw'); const cb = el('input'); cb.type = 'checkbox'; cb.id = 'cmdBg'; cb.setAttribute('role', 'switch');
  tog.append(el('span', null, 'Run in background'), cb);
  out.appendChild(tog);
  const run = el('button', 'primary', 'Run'); run.disabled = !r.runnable;
  run.onclick = () => runIt(cb.checked, false, run);
  out.appendChild(run);
  if (!r.runnable) out.appendChild(el('p', 'hint', 'Nothing to run from the phone for this route.'));
}

function pickSlot(slot) {
  const opts = (cur.candidates && cur.candidates[slot]) || [];
  const rt = cur.route, shown = slotValues(rt)[slot], now = { kind: rt.kind, project: rt.project, target: rt.target, model: rt.model, effort: rt.effort }[slot];
  openSheet(SLOT_NAMES[slot], (body) => {
    const grp = el('div', 'group'); body.appendChild(grp);
    for (const o of opts) {
      const b = el('button', 'opt'); b.appendChild(el('span', null, o.label));
      if (o.value === now || o.label === shown) b.appendChild(ic('check'));
      b.onclick = async () => {
        const r = await api2('/api/route/' + encodeURIComponent(cur.routeId) + '/slot', 'POST', JSON.stringify({ slot, value: o.value }), { 'Content-Type': 'application/json' });
        const keep = cur.routeId;
        if (r.ok) { const d = await r.json(); cur = Object.assign(cur, d); cur.routeId = keep; }
        const txt = $('cmdText') ? $('cmdText').value : ''; // sheet was replaced; rebuild the composer around the new route
        const saved = cur; await openComposer(); $('cmdText').value = txt; cur = saved;
        renderRoute(r.ok ? '' : r.status === 404 ? 'That route expired — tap Route again.' : 'That choice is not available.');
      };
      grp.appendChild(b);
    }
  });
}

const CONFIRM_WHY = {
  background_builder: 'Starts a background builder (~$5 ceiling)',
  unjudged: "Couldn't check this for danger",
  dangerous_text: 'This looks destructive',
  seat_working: 'That seat is working and sleeping it interrupts the task',
};
async function runIt(background, confirm, btn) {
  if (btn) btn.disabled = true;
  try {
    const r = await api2('/api/run', 'POST', JSON.stringify({ routeId: cur.routeId, background, confirm }), { 'Content-Type': 'application/json' });
    if (r.status === 401) { unpair(); return; }
    if (r.status === 409) {
      const d = await r.json();
      openSheet('Confirm', (body) => {
        const why = CONFIRM_WHY[d.reason] || ('This looks destructive (' + String(d.reason || 'risky').replace(/_/g, ' ') + ')');
        body.append(el('p', 'msg', why + '. Run it anyway?'));
        const yes = el('button', 'primary accent', 'Run anyway'); yes.onclick = () => runIt(background, true, yes);
        const no = el('button', 'primary alt', 'Cancel'); no.onclick = closeSheet;
        const st = el('div', 'stack'); st.append(yes, no); body.appendChild(st);
      }, 'Cancel');
      return;
    }
    if (r.ok) {
      const d = await r.json(); closeSheet();
      if (d.pane) openPane(d.pane, 'New pane'); else { banner(d.background ? 'Started in background: ' + d.background : 'Done', true); setTimeout(() => banner(''), 3000); loadList(); }
      return;
    }
    const msg = r.status === 404 ? 'That route expired — tap Route again.' : r.status === 429 ? 'Too many runs or phone builders — wait a moment.' : r.status === 403 ? 'The Mac refused this one.' : 'Failed (' + r.status + ')';
    if ($('cmdOut')) { closeSheetKeepNone(); }
    openSheet('Could not run', (body) => body.appendChild(el('p', 'msg', msg)));
  } catch (e) { openSheet('Could not run', (body) => body.appendChild(el('p', 'msg', 'Mac unreachable.'))); }
}
function closeSheetKeepNone() { /* the error sheet replaces the composer */ }

// ---------- terminal ----------
let termTimer = null;
function ensureTerm() {
  if (term) return;
  term = new Terminal({
    cols, rows, scrollback: 3000, cursorBlink: false, allowProposedApi: true, convertEol: false,
    fontFamily: 'ui-monospace, "SF Mono", Menlo, monospace', fontSize: 13,
    theme: { background: '#000000', foreground: '#f2f2f2', cursor: '#f2f2f2' },
  });
  term.open($('xt'));
  term.onData((d) => sendText(ctrlMap(d)));
  const ta = term.textarea;
  if (ta) { ta.setAttribute('inputmode', 'none'); ta.setAttribute('enterkeyhint', 'enter'); }   // tapping the terminal never opens the keyboard
}
// Ctrl armed: the next single char becomes a control char (same rule for the terminal and the message box), then it disarms.
function ctrlMap(d) {
  if (ctrl && d.length === 1) {
    const c = d.toUpperCase().charCodeAt(0);
    if (c >= 64 && c <= 95) d = String.fromCharCode(c - 64);
    setCtrl(false);
  }
  return d;
}
function setRaw(on) {
  const b = $('kbd'); b.setAttribute('aria-pressed', String(on));
  const ta = term && term.textarea; if (!ta) return;
  ta.setAttribute('inputmode', on ? 'text' : 'none');
  if (on) ta.focus(); else ta.blur();
}

function sendText(s) { if (ws && ws.readyState === 1) ws.send(enc.encode(s)); }
function setCtrl(on) { ctrl = on; $('ctrl').setAttribute('aria-pressed', String(on)); }

function applyScale() {
  if (!term) return;
  const avail = $('screen').clientWidth - 8;
  let size = 13;
  if (fit) size = Math.max(6, Math.min(15, Math.floor((avail / (cols * 0.602)) * 10) / 10));
  term.options.fontSize = size;
}

function openPane(id, title) {
  paneId = id; view = 'term'; location.hash = 'p=' + id;
  retTab = tab; $('backLbl').textContent = TAB_TITLES[tab]; $('back').setAttribute('aria-label', 'Back to ' + TAB_TITLES[tab]); clearTimeout(termTimer); for (const id of Object.values(SECTIONS)) $(id).hidden = true; showNav(false); $('term').className = 'in'; $('term').hidden = false; $('paneTitle').textContent = title || 'Pane';
  ensureTerm(); term.reset(); retry = 0; wsEverOpen = false; banner('');
  document.documentElement.classList.add('inpane'); pinned = true; setRaw(false); fitViewport(); sizeBox();
  connect();
}

function closePane() {
  view = 'list'; paneId = null; history.replaceState(null, '', location.pathname);
  setRaw(false); document.documentElement.classList.remove('inpane'); fitViewport();
  clearTimeout(retryTimer); if (ws) { ws.onclose = null; ws.close(); ws = null; }
  $('term').className = 'out'; clearTimeout(termTimer);
  termTimer = setTimeout(() => { if (view !== 'term') { $('term').hidden = true; $('term').className = ''; } }, 280);
  showNav(true); setTab(retTab); banner('');
}

function connect() {
  clearTimeout(retryTimer);
  const proto = location.protocol === 'https:' ? 'wss://' : 'ws://';
  ws = new WebSocket(proto + location.host + '/api/pane/' + paneId);
  ws.binaryType = 'arraybuffer';
  const mine = ws;
  ws.onopen = () => { ws.send(JSON.stringify({ auth: getToken() })); wsEverOpen = true; retry = 0; banner(''); };
  ws.onmessage = (ev) => {
    if (typeof ev.data === 'string') {
      const m = JSON.parse(ev.data);
      if (m.t === 'snap') { cols = m.cols; rows = m.rows; term.resize(cols, rows); applyScale(); }
      else if (m.t === 'gone') { banner('This pane was closed on the Mac.'); }
    } else { term.write(new Uint8Array(ev.data)); }
  };
  ws.onclose = (ev) => {
    if (mine !== ws || view !== 'term') return;
    if (ev.code === 4401) { unpair(); return; }
    retry++;
    banner(retry > 2 ? 'Mac asleep or offline — retrying…' : 'Reconnecting…');
    // A refused upgrade (403/404) looks like a plain close; check whether we are still paired.
    api('/api/tabs').then((r) => { if (r.status === 401) unpair(); }).catch(() => {});
    retryTimer = setTimeout(connect, Math.min(15000, 1000 * 2 ** Math.min(retry, 4)));
  };
}

// ---------- wiring ----------
$('back').onclick = closePane;
$('fit').onclick = () => { fit = !fit; $('fit').setAttribute('aria-pressed', String(fit)); applyScale(); };
$('ctrl').onclick = () => setCtrl(!ctrl);
document.querySelectorAll('.k[data-k]').forEach((b) => (b.onclick = () => sendText(KEYS[b.dataset.k])));
$('paste').onclick = async () => {
  try {
    const t = await navigator.clipboard.readText();
    if (!t) return;
    const bp = term && term.modes && term.modes.bracketedPasteMode;
    sendText(bp ? '\x1b[200~' + t + '\x1b[201~' : t);
  } catch (e) { banner('Clipboard blocked — long-press the line field to paste.'); setTimeout(() => banner(''), 3000); }
};
$('kbd').onclick = () => setRaw($('kbd').getAttribute('aria-pressed') !== 'true');

// The message box: Return is a newline; the button is Enter when empty and Send when there is text.
const box = $('text'), act = $('sendBtn');
function sizeBox() {
  box.style.height = '0'; box.style.height = box.scrollHeight + 'px';
  const empty = box.value.length === 0;
  act.classList.toggle('ready', !empty);
  act.setAttribute('aria-label', empty ? 'Press Enter' : 'Send');
}
box.addEventListener('input', (e) => {
  if (ctrl && e.data && e.data.length === 1) {   // Ctrl armed: this char goes to the pane as a control char, not into the box
    const at = box.selectionStart;
    box.value = box.value.slice(0, at - 1) + box.value.slice(at); box.setSelectionRange(at - 1, at - 1);
    sendText(ctrlMap(e.data));
  }
  sizeBox();
});
act.addEventListener('mousedown', (e) => e.preventDefault());   // keep the keyboard up when the button is tapped
$('line').onsubmit = (e) => {
  e.preventDefault();
  const v = box.value;
  if (!v) sendText('\r');
  else if (v.includes('\n')) {
    const bp = term && term.modes && term.modes.bracketedPasteMode;
    sendText(bp ? '\x1b[200~' + v + '\x1b[201~\r' : v.replace(/\r?\n/g, '\r') + '\r');
  } else sendText(v + '\r');
  box.value = ''; sizeBox();
};
const strip = $('strip');
function stripEnd() { strip.classList.toggle('end', strip.scrollLeft + strip.clientWidth >= strip.scrollWidth - 2); }
strip.addEventListener('scroll', stripEnd, { passive: true });

// Keyboard-safe pane: the page is locked, #term is sized to the visible area (so the header stays pinned and the
// composer sits on the keyboard), and the terminal stays at the bottom if it was.
let pinned = true;
function fitViewport() {
  const t = $('term'), vv = window.visualViewport;
  if (view === 'term' && vv) {
    t.style.top = vv.offsetTop + 'px'; t.style.height = vv.height + 'px'; t.style.bottom = 'auto';
    t.classList.toggle('kb', window.innerHeight - vv.height - vv.offsetTop > 80);
  } else { t.style.top = t.style.height = t.style.bottom = ''; t.classList.remove('kb'); }
  stripEnd(); placeToast();
}
if (window.visualViewport) { visualViewport.addEventListener('resize', fitViewport); visualViewport.addEventListener('scroll', fitViewport); }
const scr = $('screen');
scr.addEventListener('scroll', () => { pinned = scr.scrollHeight - scr.scrollTop - scr.clientHeight < 6; }, { passive: true });
if (window.ResizeObserver) new ResizeObserver(() => { if (pinned) scr.scrollTop = scr.scrollHeight; placeToast(); }).observe(scr);
window.addEventListener('resize', applyScale);
window.addEventListener('online', () => { if (view === 'term') { retry = 0; connect(); } else loadList(); });
document.addEventListener('visibilitychange', () => {
  if (document.hidden) return;
  if (view === 'term' && (!ws || ws.readyState > 1)) { retry = 0; connect(); }
  else if (view === 'terms') loadTerms(); else if (view === 'send') loadInbox(); else if (view === 'shots') loadShots(); else loadList();
});

const cellEls = Array.from(document.querySelectorAll('#cells span'));
function paintCode() {
  const v = $('code').value, on = document.activeElement === $('code');
  cellEls.forEach((c, i) => { c.textContent = v[i] || ''; c.classList.toggle('on', on && i === Math.min(v.length, 5)); });
}
$('code').addEventListener('input', () => { $('code').value = $('code').value.replace(/\D/g, '').slice(0, 6); paintCode(); });
$('code').addEventListener('focus', paintCode); $('code').addEventListener('blur', paintCode);
$('pairForm').onsubmit = async (e) => {
  e.preventDefault();
  const err = $('pairErr'); err.hidden = true;
  try {
    const r = await fetch('/pair', { method: 'POST', cache: 'no-store', headers: { 'Content-Type': 'application/json' },
                                     body: JSON.stringify({ code: $('code').value.trim() }) });
    const data = await r.json().catch(() => ({}));
    if (r.ok && data.token) { localStorage.setItem(TOKEN_KEY, data.token); $('code').value = ''; paintCode(); start(); return; }
    err.textContent = data.error || 'Pairing failed.'; err.hidden = false;
  } catch (x) { err.textContent = 'Could not reach the Mac.'; err.hidden = false; }
};

function start() {
  $('pair').hidden = true;
  view = 'list'; $('list').hidden = false; showNav(true); setTab('panes');
  const m = /p=([0-9a-fA-F-]{36})/.exec(location.hash);
  if (m) openPane(m[1], 'Pane'); else loadList();
}


// ---------- phone <-> Mac drop: tabs, Shots, Send ----------
let tab = 'panes', retTab = 'panes';
const SECTIONS = { panes: 'list', terms: 'termlist', shots: 'shots', send: 'send' };
let inboxTimer = null, seenInbox = new Set(), shotCache = new Map(), viewerShot = null, inboxLoaded = false;

// Every terminal pane on the Mac (GET /api/tabs), grouped by Mac tab. Tap a live one to watch and type into it; dead ones sit dimmed.
let termsLoaded = false;
async function loadTerms() {
  if (view !== 'terms' || document.hidden) return;
  const host = $('termTabs');
  if (!termsLoaded) { host.textContent = ''; host.appendChild(skeletonGroup(3)); $('termEmpty').hidden = true; }
  try {
    const tabs = await fetchTabs();
    listFails = 0; banner(''); termsLoaded = true;
    host.textContent = ''; let n = 0;
    for (const t of tabs) {
      const panes = t.panes || [];
      if (!panes.length) continue;
      n += panes.length;
      const h = tabHeader(t, panes.length);
      const grp = el('div', 'group');
      for (const { p, name, sub } of paneItems(panes, t.title)) {
        const live = p.live !== false;
        grp.appendChild(listRow({
          glyph: p.claude ? 'seat' : 'term', name, sub, dim: !live, chev: live,
          chip: !live ? { cls: 'idle', text: 'Not running' } : p.needsYou ? { cls: 'needsYou', text: 'Needs you' } : p.busy ? { cls: 'working', text: 'Working' } : { cls: 'idle', text: 'Idle' },
          onclick: () => openPane(p.id, name),
        }));
      }
      host.append(h, grp);
    }
    $('termEmpty').hidden = n > 0;
  } catch (e) {
    if (e.message === '401') return;
    if (++listFails >= 2) banner('Mac asleep or offline — retrying…');
    if (!termsLoaded) { host.textContent = ''; host.appendChild(stateBlock("Can't reach the Mac", 'Check that it is awake and True is open.', () => { listFails = 0; loadTerms(); })); }
  }
}

// ---------- pane naming + "send to session" (shared by Panes, the picker and the paperclip) ----------
const lastPart = (p) => (p || '').replace(/\/+$/, '').split('/').pop();
const shortCwd = (c) => (c || '').replace(/^\/(Users|home)\/[^/]+/, '~');
function paneName(p) { return p.agent || p.repo || lastPart(p.cwd) || p.title || 'Pane'; }
function paneSub(p) {
  if (p.topic) return p.topic;
  if (p.branch && p.branch !== 'main' && p.branch !== 'master') return p.branch;
  return shortCwd(p.cwd);
}
const realBranch = (p) => (p.branch && p.branch !== 'main' && p.branch !== 'master' ? p.branch : '');
// One tab's panes -> [{p, name, sub, generic}], needs-you first (stable). A name that repeats the tab title, or is shared
// by 2+ panes in the tab, says nothing — so the line becomes topic -> branch -> "Pane N" (N = server order) and the facts move below.
function paneItems(panes, tabTitle) {
  const key = (p) => paneName(p).toLowerCase(), count = new Map();
  panes.forEach((p) => count.set(key(p), (count.get(key(p)) || 0) + 1));
  const tt = (tabTitle || '').toLowerCase();
  const items = panes.map((p, i) => {
    if (key(p) !== tt && count.get(key(p)) === 1) return { p, name: paneName(p), sub: paneSub(p), generic: false };
    const used = p.topic || realBranch(p);
    const name = used || 'Pane ' + (i + 1);
    const sub = [p.claude ? 'Claude' : 'Shell', p.branch && p.branch !== (p.topic ? '' : realBranch(p)) ? p.branch : '',
      lastPart(p.cwd) && lastPart(p.cwd).toLowerCase() !== tt ? shortCwd(p.cwd) : ''].filter(Boolean).join(' · ');
    return { p, name, sub, generic: true, i };
  });
  const seen = new Map();   // two panes that still share a line: number them
  for (const x of items) if (x.generic) seen.set(x.name, (seen.get(x.name) || 0) + 1);
  for (const x of items) if (x.generic && seen.get(x.name) > 1) x.name += ' · Pane ' + (x.i + 1);
  return items.sort((a, b) => (b.p.needsYou - a.p.needsYou) || (panes.indexOf(a.p) - panes.indexOf(b.p)));
}
// A Mac tab's section header: title in its own case (may wrap), meta under it.
function tabHeader(t, n) {
  const h = el('h3', 'sec tab'), meta = n + (n === 1 ? ' pane' : ' panes') + (t.selected ? ' · On Mac screen' : '');
  h.append(el('span', null, t.title), el('span', 's', meta)); return h;
}
async function fetchTabs() {
  const r = await api('/api/tabs');
  if (r.status === 401) { unpair(); throw new Error('401'); }
  if (!r.ok) throw new Error(String(r.status));
  return (await r.json()).tabs || [];
}

// The one list-row component (Hub, Panes, pickers). opts: glyph, name, sub, label (small line above), chip {cls,text}, st {key,text}, chev, dim, onclick.
function listRow(o) {
  const b = el('button', 'row' + (o.dim ? ' dim' : '')), box = el('span', 't');
  if (o.label) box.appendChild(el('span', 'p', o.label));
  box.appendChild(el('span', 'n', o.name));
  if (o.sub) box.appendChild(el('span', 'c' + (o.subTone ? ' ' + o.subTone : ''), o.sub));
  b.append(glyph(o.glyph || 'term'), box);
  if (o.chip) b.appendChild(el('span', 'chip ' + o.chip.cls, o.chip.text));
  if (o.st) { const st = el('span', 'st ' + o.st.key); st.append(document.createElement('i'), el('b', null, o.st.text)); b.appendChild(st); }
  if (o.chev) { const c = ic('chev'); c.classList.add('chev'); b.appendChild(c); }
  if (o.dim) b.disabled = true; else if (o.onclick) b.onclick = o.onclick;
  return b;
}
function stateBlock(title, text, retry) {
  const d = el('div', 'empty'); d.append(el('h2', null, title), el('p', null, text));
  if (retry) { const b = el('button', 'soft', 'Retry'); b.onclick = retry; d.appendChild(b); }
  return d;
}
function skeletonGroup(n) {
  const g = el('div', 'group'); g.setAttribute('aria-hidden', 'true');
  for (let i = 0; i < n; i++) { const s = el('div', 'sk'); s.innerHTML = '<i></i><b><u></u><u></u></b>'; g.appendChild(s); }
  return g;
}

const RECENT_KEY = 'true.recentPane';
function getRecentPane() { try { return localStorage.getItem(RECENT_KEY); } catch (e) { return null; } }
function setRecentPane(id) { try { localStorage.setItem(RECENT_KEY, id); } catch (e) { /* private mode */ } }

// POST .../input {intent:stage}: puts the attachment in the pane's input box. Never retried (not idempotent).
async function stageAttachment(paneId, attach) {
  try {
    const r = await api2('/api/pane/' + encodeURIComponent(paneId) + '/input', 'POST',
      JSON.stringify({ intent: 'stage', text: '', attach: [attach] }), { 'Content-Type': 'application/json' });
    if (r.status === 401) { unpair(); return 'unpaired'; }
    if (r.status === 404) { const d = await r.json().catch(() => ({})); return /attachment/i.test(d.error || '') ? 'noAttach' : 'noPane'; }
    if (!r.ok) return 'error';
    const d = await r.json().catch(() => ({}));
    return d.outcome || 'staged';
  } catch (e) { return 'error'; }
}
function toast(msg) { banner(msg, true); setTimeout(() => banner(''), 3200); }
// outcome -> { msg, open (go to the pane), keep (leave the picker up) }
function outcomeInfo(outcome, name) {
  switch (outcome) {
    case 'staged': case 'landed': return { msg: 'Added to ' + name + ' — type your message', open: true };
    case 'stuckInComposer': return { msg: "It's in " + name + "'s input box but didn't go further", open: true };
    case 'promptGone': return { msg: name + ' moved on before it arrived', open: true };
    case 'noPane': return { msg: 'That pane closed — pick another', keep: true };
    case 'noAttach': return { msg: 'That shot is gone from the Mac' };
    case 'error': return { msg: "Couldn't send — nothing was added", keep: true };
    default: return { msg: 'Sent to ' + name + ", couldn't confirm — check it", open: true };   // unverified
  }
}

// Pane picker sheet: refetches /api/tabs on every open. onPick(pane, name) resolves to an outcome string.
function openPicker(attach, stay) {
  let body = null, sending = false;
  const paint = (fn) => { body.textContent = ''; fn(); };
  const load = async () => {
    paint(() => body.appendChild(skeletonGroup(3)));
    let tabs;
    try { tabs = await fetchTabs(); } catch (e) { if (String(e.message) !== '401') paint(() => body.appendChild(stateBlock("Can't reach the Mac", 'Check it is awake and on Tailscale.', load))); return; }
    show(tabs);
  };
  const pick = async (p, name) => {
    if (sending) return; sending = true; body.classList.add('busy');
    const outcome = await stageAttachment(p.id, attach);
    sending = false; body.classList.remove('busy');
    if (outcome === 'unpaired') return;
    const info = outcomeInfo(outcome, name);
    if (info.open) setRecentPane(p.id);
    if (info.keep) { toast(info.msg); load(); return; }
    closeSheet();
    if (info.open && !stay) { $('viewer').hidden = true; viewerShot = null; openPane(p.id, name); }
    toast(info.msg);
  };
  const show = (tabs) => paint(() => {
    const groups = tabs.map((t) => ({ t, items: paneItems(t.panes || [], t.title).sort((a, b) => (b.p.live - a.p.live) || (b.p.claude - a.p.claude)) }));
    const all = groups.flatMap((g) => g.items);
    if (!all.some((x) => x.p.live)) { body.appendChild(stateBlock('No open panes on the Mac', 'Open a pane on the Mac and it shows up here.')); return; }
    const row = (x) => listRow({ glyph: x.p.claude ? 'seat' : 'term', name: x.name, sub: x.p.claude || x.generic ? x.sub : 'Shell · ' + x.sub, dim: !x.p.live,
      chip: x.p.live ? null : { cls: 'idle', text: 'Not running' }, onclick: () => pick(x.p, x.name) });
    const rec = all.find((x) => x.p.live && x.p.id === getRecentPane());
    if (rec) { body.appendChild(el('h3', 'sec', 'Recent')); const g = el('div', 'group'); g.appendChild(row(rec)); body.appendChild(g); }
    for (const { t, items } of groups) {
      if (!items.length) continue;
      body.appendChild(tabHeader(t, (t.panes || []).length));
      const g = el('div', 'group'); items.forEach((x) => g.appendChild(row(x))); body.appendChild(g);
    }
  });
  openSheet('Send to session', (b) => { body = b; }, 'Cancel');
  load();
}

function showNav(on) { $('nav').hidden = !on; document.body.classList.toggle('hasnav', on); }
const TAB_TITLES = { panes: 'Hub', terms: 'Panes', shots: 'Shots', send: 'Send' };
function setTab(name) {
  tab = name; $('inTitle').textContent = TAB_TITLES[name]; window.scrollTo(0, 0); document.body.classList.remove('scrolled'); view = name === 'panes' ? 'list' : name;
  for (const [t, id] of Object.entries(SECTIONS)) $(id).hidden = t !== name;
  document.querySelectorAll('#tabbar button').forEach((b) => { if (b.dataset.tab === name) b.setAttribute('aria-current', 'page'); else b.removeAttribute('aria-current'); });
  clearInterval(inboxTimer); inboxTimer = null; clearInterval(shotsTimer); shotsTimer = null;
  if (name === 'panes') loadList();
  if (name === 'terms') loadTerms();
  if (name === 'shots') { shotIds = ''; loadShots(); shotsTimer = setInterval(loadShots, 4000); }
  if (name === 'send') { $('dot').hidden = true; loadInbox(); inboxTimer = setInterval(loadInbox, 5000); }
}
document.querySelectorAll('#tabbar button').forEach((b) => (b.onclick = () => setTab(b.dataset.tab)));

window.addEventListener('scroll', () => document.body.classList.toggle('scrolled', window.scrollY > 44), { passive: true });

// Bearer-authenticated blob fetch (an <img src> cannot send the Authorization header).
const blobUrls = new Map();
async function blobFor(path) {
  if (blobUrls.has(path)) return blobUrls.get(path);
  const r = await api(path);
  if (r.status === 401) { unpair(); throw new Error('401'); }
  if (!r.ok) throw new Error(String(r.status));
  const b = await r.blob();
  const e = { blob: b, url: URL.createObjectURL(b) };
  blobUrls.set(path, e);
  return e;
}

// Live pull: the Mac copies each new screenshot into the tray the moment it lands; the phone re-lists every 4 s while
// this tab is open and only adds what is new. Grid tiles use the small /thumb JPEG, the viewer the full image.
let shotsTimer = null, shotIds = '';
async function thumbFor(id, tries = 3) {
  for (let i = 0; i < tries; i++) {
    try { return await blobFor('/api/shots/' + id + '/thumb'); }
    catch (e) { if (String(e.message) === '401' || i === tries - 1) throw e; await new Promise((r) => setTimeout(r, 800 * (i + 1))); }
  }
}
async function loadShots() {
  if (view !== 'shots' || document.hidden) return;
  try {
    const r = await api('/api/shots');
    if (r.status === 401) { unpair(); return; }
    if (!r.ok) throw new Error(String(r.status));
    const shots = (await r.json()).shots || [];
    banner('');
    $('shotsEmpty').hidden = shots.length > 0;
    const ids = shots.map((s) => s.id).join();
    if (ids === shotIds) return;
    shotIds = ids;
    const g = $('grid'); g.textContent = '';
    for (const s of shots) {
      const b = document.createElement('button'); b.setAttribute('aria-label', 'Screenshot ' + s.created);
      const img = document.createElement('img'); img.alt = ''; img.decoding = 'async'; b.appendChild(img);
      thumbFor(s.id).then((e) => { img.src = e.url; }).catch(() => { b.classList.add('failed'); });
      b.onclick = () => openViewer(s);
      g.appendChild(b);
    }
  } catch (e) { banner('Mac asleep or offline — retrying…'); }
}

function extFor(type) { return ({ 'image/png': 'png', 'image/jpeg': 'jpg', 'image/gif': 'gif', 'image/webp': 'webp', 'image/heic': 'heic', 'image/heif': 'heif', 'image/tiff': 'tif' })[type] || 'png'; }
async function openViewer(s) {
  const path = '/api/shots/' + s.id;
  try {
    const e = await blobFor(path);
    viewerShot = { id: s.id, blob: e.blob, name: 'True-' + s.id + '.' + extFor(e.blob.type) };
    $('vBody').textContent = '';
    const img = document.createElement('img'); img.src = e.url; img.alt = 'Screenshot'; $('vBody').appendChild(img);
    $('vTitle').textContent = new Date(s.created).toLocaleString();
    $('viewer').hidden = false;
  } catch (x) { banner('Could not load that shot.'); setTimeout(() => banner(''), 3000); }
}
$('vClose').onclick = () => { $('viewer').hidden = true; viewerShot = null; };
async function shareBlob(blob, name) {
  const f = new File([blob], name, { type: blob.type || 'application/octet-stream' });
  if (navigator.canShare && navigator.canShare({ files: [f] })) {
    try { await navigator.share({ files: [f] }); } catch (e) { /* cancelled */ }
  } else saveBlob(blob, name);
}
function saveBlob(blob, name) {
  const a = document.createElement('a'); a.href = URL.createObjectURL(blob); a.download = name;
  document.body.appendChild(a); a.click(); a.remove(); setTimeout(() => URL.revokeObjectURL(a.href), 10000);
}
$('vSend').onclick = () => viewerShot && openPicker({ id: viewerShot.id });
$('vShare').onclick = () => viewerShot && shareBlob(viewerShot.blob, viewerShot.name);
$('vSave').onclick = () => viewerShot && saveBlob(viewerShot.blob, viewerShot.name);

// ----- inbox (Mac pushed to the phone) -----
async function loadInbox() {
  if (view !== 'send' || document.hidden) return;
  try {
    const r = await api('/api/inbox');
    if (r.status === 401) { unpair(); return; }
    if (!r.ok) throw new Error(String(r.status));
    const items = (await r.json()).items || [];
    seenInbox = new Set(items.map((i) => i.id));
    renderInbox(items); banner('');
  } catch (e) { /* next poll */ }
}
function btn(label, fn) { const b = document.createElement('button'); b.className = 'btn'; b.textContent = label; b.onclick = fn; return b; }
function renderInbox(items) {
  $('inboxBox').hidden = items.length === 0;
  const host = $('inbox'); host.textContent = '';
  for (const i of items) {
    const row = document.createElement('div'); row.className = 'item';
    const t = document.createElement('span'); t.className = 't';
    const n = document.createElement('span'); n.className = 'n'; n.textContent = i.kind === 'text' ? 'Clipboard' : i.name;
    const c = document.createElement('span'); c.className = 'c';
    c.textContent = i.kind === 'text' ? (i.preview || '') : fmtSize(i.size);
    t.append(n, c); row.append(glyph(i.kind === 'text' ? 'quote' : 'doc'), t);
    if (i.kind === 'text') {
      row.appendChild(btn('Copy', async () => {
        try { const e = await api('/api/inbox/' + i.id); await navigator.clipboard.writeText(await e.text()); flash(row, 'Copied'); }
        catch (x) { flash(row, 'Blocked'); }
      }));
    } else {
      row.appendChild(btn('Save', async () => {
        try { const e = await blobFor('/api/inbox/' + i.id); await shareBlob(e.blob, i.name); } catch (x) { flash(row, 'Failed'); }
      }));
    }
    const x = document.createElement('button'); x.className = 'x'; x.setAttribute('aria-label', 'Remove'); x.appendChild(ic('x'));
    x.onclick = async () => { await api2('/api/inbox/' + i.id, 'DELETE'); blobUrls.delete('/api/inbox/' + i.id); loadInbox(); };
    row.appendChild(x);
    host.appendChild(row);
  }
}
function flash(row, text) { const c = row.querySelector('.c'); if (c) c.textContent = text; }
function fmtSize(n) { return n > 1048576 ? (n / 1048576).toFixed(1) + ' MB' : Math.max(1, Math.round(n / 1024)) + ' KB'; }
function api2(path, method, body, headers) {
  return fetch(path, { method, cache: 'no-store', body, headers: Object.assign({ Authorization: 'Bearer ' + getToken() }, headers || {}) });
}
// A quiet dot on the Send tab when the Mac pushes something while we are elsewhere.
async function peekInbox() {
  if (view === 'send' || document.hidden || !getToken()) return;
  try {
    const r = await api('/api/inbox'); if (!r.ok) return;
    const items = (await r.json()).items || [];
    if (inboxLoaded && items.some((i) => !seenInbox.has(i.id))) $('dot').hidden = false;
    items.forEach((i) => seenInbox.add(i.id)); inboxLoaded = true;
  } catch (e) { /* offline */ }
}
setInterval(peekInbox, 15000);

// ----- upload (phone -> Mac) -----
const UPLOAD_ERR = { 413: 'Too big (200 MB max)', 507: 'Mac disk is full', 408: 'Timed out', 503: 'Mac is busy, try again' };
// One raw-body POST to /api/drop. Returns { promise, abort }; the promise resolves with the reply JSON and rejects with
// { msg } (or { aborted }). The Mac takes 2 uploads at a time; a 503 means "busy" — wait 1s, 2s, 4s… (6 tries) and go again.
function uploadFile(file, hooks) {
  hooks = hooks || {};
  let xhr = null, timer = null, dead = false, rej = null;
  const promise = new Promise((resolve, reject) => {
    rej = reject;
    const attempt = (n) => {
      const x = xhr = new XMLHttpRequest();
      x.open('POST', '/api/drop');
      x.setRequestHeader('Authorization', 'Bearer ' + getToken());
      x.setRequestHeader('X-Filename', encodeURIComponent(file.name || 'iPhone-upload'));
      x.upload.onprogress = (e) => { if (e.lengthComputable && hooks.onProgress) hooks.onProgress(Math.round((e.loaded / e.total) * 100)); };
      x.onload = () => {
        if (dead) return;
        if (x.status === 401) { unpair(); reject({ msg: '', unpaired: true }); return; }
        if (x.status === 503 && n < 6) { if (hooks.onWait) hooks.onWait(); timer = setTimeout(() => attempt(n + 1), 1000 * 2 ** n); return; }
        if (x.status >= 200 && x.status < 300) { let d = {}; try { d = JSON.parse(x.responseText); } catch (e) { /* plain ok */ } resolve(d); }
        else reject({ msg: UPLOAD_ERR[x.status] || 'Failed (' + x.status + ')' });
      };
      x.onerror = () => { if (!dead) reject({ msg: 'Mac unreachable' }); };
      x.send(file);
    };
    attempt(0);
  });
  return { promise, abort() { dead = true; clearTimeout(timer); if (xhr) xhr.abort(); rej({ aborted: true }); } };
}

$('pick').onclick = () => $('files').click();
$('files').onchange = () => { const fs = Array.from($('files').files); $('files').value = ''; fs.forEach(upload); };
function upload(file) {
  const row = document.createElement('div'); row.className = 'up';
  const n = document.createElement('div'); n.className = 'n';
  const nm = document.createElement('span'); nm.textContent = file.name || 'file';
  const st = document.createElement('span'); st.className = 'st'; st.textContent = '0%';
  n.append(nm, st);
  const pr = document.createElement('div'); pr.className = 'bar4'; const fill = document.createElement('i'); pr.appendChild(fill);
  const setP = (p) => { fill.style.width = p + '%'; st.textContent = p + '%'; };
  row.append(n, pr); $('uploads').prepend(row);
  uploadFile(file, { onProgress: setP, onWait: () => { fill.style.width = '0%'; st.textContent = 'Waiting…'; } }).promise.then(() => {
    fill.style.width = '100%'; st.textContent = 'Sent'; setTimeout(() => row.remove(), 6000);
  }, (e) => { if (e.unpaired) return; row.classList.add('bad'); st.textContent = e.msg; pr.hidden = true; });
}

// ----- paperclip inside a pane: phone photo or a Mac shot -> /api/drop -> stage into this pane -----
let chipJob = null;
function paneNameNow() { return $('paneTitle').textContent || 'the pane'; }
async function stageHere(attach, pid) {
  const outcome = await stageAttachment(pid, attach);
  if (outcome === 'unpaired') return;
  toast(outcomeInfo(outcome, paneNameNow()).msg);   // stays in the pane either way
}
function attachPhoto(file) {
  const pid = paneId, chip = $('upchip'), act = $('upAct');
  const url = URL.createObjectURL(file), img = $('upThumb');
  img.onerror = () => { img.style.visibility = 'hidden'; }; img.style.visibility = ''; img.src = url;
  $('upName').textContent = file.name || 'Photo';
  const fill = $('upBar').firstElementChild, state = $('upState');
  const done = () => { chip.hidden = true; chipJob = null; URL.revokeObjectURL(url); };
  const run = () => {
    chip.hidden = false; chip.classList.remove('bad'); $('upBar').hidden = false; fill.style.width = '0%'; state.textContent = 'Uploading…';
    act.textContent = 'Cancel';
    const job = chipJob = uploadFile(file, { onProgress: (p) => { fill.style.width = p + '%'; state.textContent = p + '%'; }, onWait: () => { state.textContent = 'Waiting…'; } });
    act.onclick = () => { job.abort(); };
    job.promise.then(async (d) => {
      done();
      if (d.where === 'shots' && d.id) await stageHere({ id: d.id }, pid);
      else toast('Saved to Downloads on the Mac');
    }, (e) => {
      if (e.unpaired) return;
      if (e.aborted) { done(); return; }
      chip.classList.add('bad'); $('upBar').hidden = true; state.textContent = e.msg; act.textContent = 'Retry'; act.onclick = run; chipJob = null;
    });
  };
  run();
}
$('clip').onclick = () => {
  openSheet('Attach an image', (body) => {
    const g = el('div', 'group');
    const mk = (g1, name, sub, fn) => { const b = listRow({ glyph: g1, name, sub, chev: true, onclick: fn }); g.appendChild(b); };
    mk('doc', 'Photo from iPhone', 'Photos, camera or Files', () => { closeSheet(); $('paneFile').click(); });
    mk('doc', 'From Mac Shots', 'Recent screenshots on the Mac', () => macShotsSheet());
    body.appendChild(g);
  }, 'Cancel');
};
$('paneFile').onchange = () => { const f = $('paneFile').files[0]; $('paneFile').value = ''; if (f && view === 'term') attachPhoto(f); };
async function macShotsSheet() {
  const pid = paneId; let body = null;
  const paint = (fn) => { body.textContent = ''; fn(); };
  const load = async () => {
    paint(() => body.appendChild(skeletonGroup(2)));
    try {
      const r = await api('/api/shots');
      if (r.status === 401) { unpair(); return; }
      if (!r.ok) throw new Error(String(r.status));
      const shots = (await r.json()).shots || [];
      paint(() => {
        if (!shots.length) { body.appendChild(stateBlock('No screenshots yet', 'Screenshots on the Mac appear here.')); return; }
        const g = el('div', 'shotgrid');
        for (const s of shots.slice(0, 30)) {
          const b = document.createElement('button'); b.setAttribute('aria-label', 'Screenshot ' + s.created);
          const img = document.createElement('img'); img.alt = ''; b.appendChild(img);
          thumbFor(s.id).then((e) => { img.src = e.url; }).catch(() => b.classList.add('failed'));
          b.onclick = () => { closeSheet(); stageHere({ id: s.id }, pid); };
          g.appendChild(b);
        }
        body.appendChild(g);
      });
    } catch (e) { paint(() => body.appendChild(stateBlock("Can't reach the Mac", 'Check it is awake and on Tailscale.', load))); }
  };
  openSheet('Mac Shots', (b) => { body = b; }, 'Cancel');
  load();
}

$('clipSend').onclick = async () => {
  const t = $('clipText').value; if (!t) return;
  const note = $('clipNote'); note.textContent = 'Sending…';
  try {
    const r = await api2('/api/clip', 'POST', JSON.stringify({ text: t }), { 'Content-Type': 'application/json' });
    if (r.status === 401) { unpair(); return; }
    if (r.ok) { note.textContent = 'On the Mac clipboard'; $('clipText').value = ''; }
    else note.textContent = r.status === 413 ? 'Too long (256 KB max).' : 'Failed (' + r.status + ')';
  } catch (e) { note.textContent = 'Mac unreachable.'; }
};

setInterval(loadList, 5000);   // Hub poll: only while visible (loadList bails when hidden)
if (getToken()) start(); else unpair();
