'use strict';
// True on the web: a thin window onto panes the Mac already has open. The Mac stays authoritative:
// this page never resizes a PTY, it renders at the Mac's cols and scales/scrolls to fit.
const $ = (id) => document.getElementById(id);
const enc = new TextEncoder();
const KEYS = { esc: '\x1b', tab: '\t', up: '\x1b[A', down: '\x1b[B', right: '\x1b[C', left: '\x1b[D', cc: '\x03' };

// Pairing token: localStorage + Authorization header, never a cookie (cookies ignore ports and would also reach
// other services on the same *.ts.net hostname).
const TOKEN_KEY = 'true.token';
const getToken = () => localStorage.getItem(TOKEN_KEY);
function api(path) { return fetch(path, { cache: 'no-store', headers: { Authorization: 'Bearer ' + getToken() } }); }
function unpair() {
  localStorage.removeItem(TOKEN_KEY); view = 'pair'; paneId = null;
  clearTimeout(retryTimer); if (ws) { ws.onclose = null; ws.close(); ws = null; }
  for (const id of ['list', 'termlist', 'term', 'shots', 'send', 'viewer', 'sheet']) $(id).hidden = true;
  $('nav').hidden = true; document.body.classList.remove('hasnav'); $('pair').hidden = false; banner('');
}

let view = 'list', paneId = null, term = null, ws = null, cols = 80, rows = 24;
let fit = true, ctrl = false, retry = 0, retryTimer = null, listFails = 0, wsEverOpen = false;

function banner(msg) { const b = $('banner'); b.textContent = msg || ''; b.hidden = !msg; }

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
    if (++listFails >= 2) banner('Mac asleep or offline — retrying…');
  }
}

function el(tag, cls, text) { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; }

function renderHub(data) {
  const host = $('tabs'); host.textContent = '';
  let n = 0;
  $('hubSummary').textContent = data.summary || '';
  for (const g of data.projects || []) {
    const sec = el('section', 'tab');
    sec.appendChild(el('h2', null, g.title + (g.summary ? ' · ' + g.summary : '')));
    for (const r of g.rows || []) {
      n++;
      const b = el('button', 'row2');
      const box = el('span', 't');
      box.append(el('span', 'n', r.name), el('span', 'c', [r.cwd, r.elapsed].filter(Boolean).join(' · ')));
      b.appendChild(box);
      b.appendChild(el('span', 'chip ' + (r.statusKey || 'idle'), r.status));
      b.onclick = () => rowTap(r);
      sec.appendChild(b);
    }
    host.appendChild(sec);
  }
  $('empty').hidden = n > 0;
  $('clock').textContent = new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
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
function openSheet(title, fill) {
  $('sheetTitle').textContent = title; const body = $('sheetBody'); body.textContent = '';
  fill(body); $('sheet').hidden = false;
}
function closeSheet() { $('sheet').hidden = true; $('sheetBody').textContent = ''; }
$('sheetClose').onclick = closeSheet; $('sheetBack').onclick = closeSheet;

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
        const ack = el('button', 'big', 'Ack');
        ack.onclick = async () => {
          ack.disabled = true;
          const x = await api2('/api/hub/builder/' + encodeURIComponent(r.builderId) + '/ack', 'POST', '{}', { 'Content-Type': 'application/json' });
          if (x.ok) { closeSheet(); loadList(); } else { ack.disabled = false; ack.textContent = 'Failed (' + x.status + ') — retry'; }
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
    const t = el('textarea', 'field'); t.id = 'cmdText'; t.rows = 3; t.maxLength = 4000; t.placeholder = 'What should happen? (fix the login test in true…)';
    t.setAttribute('aria-label', 'Command');
    const go = el('button', 'big', 'Route'); go.id = 'cmdRoute';
    const out = el('div'); out.id = 'cmdOut';
    const rec = el('div', 'recent'); rec.id = 'cmdRecent';
    // One line only: a line break would act as Enter in a shell, so it is never sent.
    t.addEventListener('keydown', (ev) => { if (ev.key === 'Enter') { ev.preventDefault(); go.click(); } });
    t.addEventListener('input', () => { if (/[\r\n]/.test(t.value)) t.value = t.value.replace(/[\r\n]+/g, ' '); });
    go.onclick = () => routeIt(t.value.replace(/[\r\n]+/g, ' '));
    body.append(t, go, out, rec);
    t.focus(); loadRecent(t);
  });
}

async function loadRecent(t) {
  try {
    const r = await api('/api/recent'); if (!r.ok) return;
    const d = await r.json(); const host = $('cmdRecent'); if (!host || !(d.items || []).length) return;
    host.appendChild(el('h3', null, 'Recent'));
    for (const s of d.items.slice(0, 12)) { const b = el('button', null, s); b.onclick = () => { t.value = s; t.focus(); }; host.appendChild(b); }
  } catch (e) { /* history is optional */ }
}

async function routeIt(text) {
  const out = $('cmdOut'); out.textContent = '';
  if (!text.trim()) return;
  out.appendChild(el('p', 'hint', 'Routing…'));
  try {
    const r = await api2('/api/route', 'POST', JSON.stringify({ text }), { 'Content-Type': 'application/json' });
    if (r.status === 401) { unpair(); return; }
    if (r.status === 429) { out.textContent = ''; out.appendChild(el('p', 'msg', 'Slow down — too many requests.')); return; }
    if (!r.ok) throw new Error(String(r.status));
    cur = await r.json(); renderRoute();
  } catch (e) { out.textContent = ''; out.appendChild(el('p', 'msg', 'Could not route (Mac offline?)')); }
}

function renderRoute(note) {
  const out = $('cmdOut'); out.textContent = '';
  const r = cur.route;
  const chips = el('div', 'chips');
  const vals = { kind: r.kindLabel, project: r.project || '—', target: r.where, model: r.model || 'default', effort: r.effort || 'default' };
  for (const s of Object.keys(SLOT_NAMES)) {
    if (!(cur.candidates && cur.candidates[s] && cur.candidates[s].length)) continue;
    const c = el('button', 'rc' + (r.uncertain && r.uncertain.includes(s) ? ' unsure' : '') + (s === 'kind' && r.dangerous ? ' danger' : ''), vals[s]);
    c.setAttribute('aria-label', SLOT_NAMES[s] + ': ' + vals[s]);
    c.onclick = () => pickSlot(s);
    chips.appendChild(c);
  }
  out.appendChild(chips);
  if (note) out.appendChild(el('p', 'msg', note));
  if (r.twoChoice) out.appendChild(el('p', 'hint', 'Not sure what this is — pick a kind above.'));
  if (r.dangerous) out.appendChild(el('p', 'msg', 'Looks risky — you will be asked to confirm.'));
  const tog = el('label', 'tog'); const cb = el('input'); cb.type = 'checkbox'; cb.id = 'cmdBg';
  tog.append(cb, document.createTextNode('Run in background'));
  out.appendChild(tog);
  const run = el('button', 'big', 'Run'); run.disabled = !r.runnable;
  run.onclick = () => runIt(cb.checked, false, run);
  out.appendChild(run);
  if (!r.runnable) out.appendChild(el('p', 'hint', 'Nothing to run from the phone for this route.'));
}

function pickSlot(slot) {
  const opts = (cur.candidates && cur.candidates[slot]) || [];
  openSheet(SLOT_NAMES[slot], (body) => {
    for (const o of opts) {
      const b = el('button', 'opt', o.label); b.onclick = async () => {
        const r = await api2('/api/route/' + encodeURIComponent(cur.routeId) + '/slot', 'POST', JSON.stringify({ slot, value: o.value }), { 'Content-Type': 'application/json' });
        const keep = cur.routeId;
        if (r.ok) { const d = await r.json(); cur = Object.assign(cur, d); cur.routeId = keep; }
        const txt = $('cmdText') ? $('cmdText').value : ''; // sheet was replaced; rebuild the composer around the new route
        const saved = cur; await openComposer(); $('cmdText').value = txt; cur = saved;
        renderRoute(r.ok ? '' : r.status === 404 ? 'That route expired — tap Route again.' : 'That choice is not available.');
      };
      body.appendChild(b);
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
        const yes = el('button', 'big', 'Run anyway'); yes.onclick = () => runIt(background, true, yes);
        const no = el('button', 'big alt', 'Cancel'); no.onclick = closeSheet;
        body.append(yes, no);
      });
      return;
    }
    if (r.ok) {
      const d = await r.json(); closeSheet();
      if (d.pane) openPane(d.pane, 'New pane'); else { banner(d.background ? 'Started in background: ' + d.background : 'Done'); setTimeout(() => banner(''), 3000); loadList(); }
      return;
    }
    const msg = r.status === 404 ? 'That route expired — tap Route again.' : r.status === 429 ? 'Too many runs or phone builders — wait a moment.' : r.status === 403 ? 'The Mac refused this one.' : 'Failed (' + r.status + ')';
    if ($('cmdOut')) { closeSheetKeepNone(); }
    openSheet('Could not run', (body) => body.appendChild(el('p', 'msg', msg)));
  } catch (e) { openSheet('Could not run', (body) => body.appendChild(el('p', 'msg', 'Mac unreachable.'))); }
}
function closeSheetKeepNone() { /* the error sheet replaces the composer */ }

// ---------- terminal ----------
function ensureTerm() {
  if (term) return;
  term = new Terminal({
    cols, rows, scrollback: 3000, cursorBlink: false, allowProposedApi: true, convertEol: false,
    fontFamily: 'ui-monospace, "SF Mono", Menlo, monospace', fontSize: 13,
    theme: { background: '#000000', foreground: '#f2f2f2', cursor: '#f2f2f2' },
  });
  term.open($('xt'));
  term.onData((d) => {
    if (ctrl && d.length === 1) {
      const c = d.toUpperCase().charCodeAt(0);
      if (c >= 64 && c <= 95) d = String.fromCharCode(c - 64);
      setCtrl(false);
    }
    sendText(d);
  });
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
  retTab = tab; for (const id of Object.values(SECTIONS)) $(id).hidden = true; showNav(false); $('term').hidden = false; $('paneTitle').textContent = title || 'Pane';
  ensureTerm(); term.reset(); retry = 0; wsEverOpen = false; banner('');
  connect();
}

function closePane() {
  view = 'list'; paneId = null; history.replaceState(null, '', location.pathname);
  clearTimeout(retryTimer); if (ws) { ws.onclose = null; ws.close(); ws = null; }
  $('term').hidden = true; showNav(true); setTab(retTab); banner('');
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
$('line').onsubmit = (e) => { e.preventDefault(); const f = $('text'); sendText(f.value + '\r'); f.value = ''; };
window.addEventListener('resize', applyScale);
window.addEventListener('online', () => { if (view === 'term') { retry = 0; connect(); } else loadList(); });
document.addEventListener('visibilitychange', () => {
  if (document.hidden) return;
  if (view === 'term' && (!ws || ws.readyState > 1)) { retry = 0; connect(); }
  else if (view === 'terms') loadTerms(); else if (view === 'send') loadInbox(); else if (view === 'shots') loadShots(); else loadList();
});

$('pairForm').onsubmit = async (e) => {
  e.preventDefault();
  const err = $('pairErr'); err.hidden = true;
  try {
    const r = await fetch('/pair', { method: 'POST', cache: 'no-store', headers: { 'Content-Type': 'application/json' },
                                     body: JSON.stringify({ code: $('code').value.trim() }) });
    const data = await r.json().catch(() => ({}));
    if (r.ok && data.token) { localStorage.setItem(TOKEN_KEY, data.token); $('code').value = ''; start(); return; }
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

// Every live terminal pane on the Mac (GET /api/tabs), grouped by Mac tab. Tap one to watch and type into it.
async function loadTerms() {
  if (view !== 'terms' || document.hidden) return;
  try {
    const r = await api('/api/tabs');
    if (r.status === 401) { unpair(); return; }
    if (!r.ok) throw new Error(String(r.status));
    const tabs = (await r.json()).tabs || [];
    listFails = 0; banner('');
    const host = $('termTabs'); host.textContent = ''; let n = 0;
    for (const t of tabs) {
      const live = (t.panes || []).filter((p) => p.live);
      if (!live.length) continue;
      const sec = el('section', 'tab');
      sec.appendChild(el('h2', null, t.title));
      for (const p of live) {
        n++;
        const b = el('button', 'row2'), box = el('span', 't');
        box.append(el('span', 'n', p.title), el('span', 'c', p.cwd || ''));
        b.append(box, el('span', 'chip ' + (p.needsYou ? 'needsYou' : p.busy ? 'working' : 'idle'), p.needsYou ? 'Needs you' : p.busy ? 'Working' : 'Idle'));
        b.onclick = () => openPane(p.id, p.title);
        sec.appendChild(b);
      }
      host.appendChild(sec);
    }
    $('termEmpty').hidden = n > 0;
  } catch (e) { if (++listFails >= 2) banner('Mac asleep or offline — retrying…'); }
}

function showNav(on) { $('nav').hidden = !on; document.body.classList.toggle('hasnav', on); }
function setTab(name) {
  tab = name; view = name === 'panes' ? 'list' : name;
  for (const [t, id] of Object.entries(SECTIONS)) $(id).hidden = t !== name;
  document.querySelectorAll('#nav button').forEach((b) => { if (b.dataset.tab === name) b.setAttribute('aria-current', 'page'); else b.removeAttribute('aria-current'); });
  clearInterval(inboxTimer); inboxTimer = null; clearInterval(shotsTimer); shotsTimer = null;
  if (name === 'panes') loadList();
  if (name === 'terms') loadTerms();
  if (name === 'shots') { shotIds = ''; loadShots(); shotsTimer = setInterval(loadShots, 4000); }
  if (name === 'send') { $('dot').hidden = true; loadInbox(); inboxTimer = setInterval(loadInbox, 5000); }
}
document.querySelectorAll('#nav button').forEach((b) => (b.onclick = () => setTab(b.dataset.tab)));

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
    viewerShot = { blob: e.blob, name: 'True-' + s.id + '.' + extFor(e.blob.type) };
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
    t.append(n, c); row.appendChild(t);
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
    row.appendChild(btn('✕', async () => {
      await api2('/api/inbox/' + i.id, 'DELETE'); blobUrls.delete('/api/inbox/' + i.id); loadInbox();
    }));
    row.lastChild.setAttribute('aria-label', 'Remove');
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
$('pick').onclick = () => $('files').click();
$('files').onchange = () => { const fs = Array.from($('files').files); $('files').value = ''; fs.forEach(upload); };
function upload(file) {
  const row = document.createElement('div'); row.className = 'up';
  const n = document.createElement('div'); n.className = 'n';
  const nm = document.createElement('span'); nm.textContent = file.name || 'file';
  const st = document.createElement('span'); st.className = 'st'; st.textContent = '0%';
  n.append(nm, st);
  const pr = document.createElement('progress'); pr.max = 100; pr.value = 0;
  row.append(n, pr); $('uploads').prepend(row);
  const fail = (m) => { row.classList.add('bad'); st.textContent = m; pr.hidden = true; };
  const attempt = (n) => {
  const x = new XMLHttpRequest();
  x.open('POST', '/api/drop');
  x.setRequestHeader('Authorization', 'Bearer ' + getToken());
  x.setRequestHeader('X-Filename', encodeURIComponent(file.name || 'iPhone-upload'));
  x.upload.onprogress = (e) => { if (e.lengthComputable) { const p = Math.round((e.loaded / e.total) * 100); pr.value = p; st.textContent = p + '%'; } };
  x.onload = () => {
    if (x.status === 401) { unpair(); return; }
    // The Mac takes 2 uploads at a time; a 503 means "busy" — wait 1s, 2s, 4s… (6 tries) and go again.
    if (x.status === 503 && n < 6) { pr.value = 0; st.textContent = 'Waiting…'; setTimeout(() => attempt(n + 1), 1000 * 2 ** n); return; }
    if (x.status >= 200 && x.status < 300) { pr.value = 100; st.textContent = 'Sent ✓'; setTimeout(() => row.remove(), 6000); }
    else fail(({ 413: 'Too big (200 MB max)', 507: 'Mac disk is full', 408: 'Timed out', 503: 'Mac is busy, try again' })[x.status] || 'Failed (' + x.status + ')');
  };
  x.onerror = () => fail('Mac unreachable');
  x.send(file);
  };
  attempt(0);
}

$('clipSend').onclick = async () => {
  const t = $('clipText').value; if (!t) return;
  const note = $('clipNote'); note.textContent = 'Sending…';
  try {
    const r = await api2('/api/clip', 'POST', JSON.stringify({ text: t }), { 'Content-Type': 'application/json' });
    if (r.status === 401) { unpair(); return; }
    if (r.ok) { note.textContent = 'On the Mac clipboard ✓'; $('clipText').value = ''; }
    else note.textContent = r.status === 413 ? 'Too long (256 KB max).' : 'Failed (' + r.status + ')';
  } catch (e) { note.textContent = 'Mac unreachable.'; }
};

setInterval(loadList, 5000);   // Hub poll: only while visible (loadList bails when hidden)
if (getToken()) start(); else unpair();
