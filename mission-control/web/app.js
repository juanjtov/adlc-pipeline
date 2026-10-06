// ADLC Mission Control: the page. No build step, no dependencies.
// It renders one state document (built by the server in mc/state.py, or by demo.js in demo mode)
// and patches the page in place, so animations and scroll positions survive every update.

import { createDemo } from './demo.js';

// ------------------------------------------------------------------------------------ the line
const SLOTS = ['intake', 'analyst', 'gate1', 'architect', 'builder', 'reviewer', 'qa', 'gate2', 'done'];
const STATIONS = ['analyst', 'architect', 'builder', 'reviewer', 'qa'];
const WEIGHT = [0.56, 1, 0.6, 1, 1, 1, 1, 0.6, 0.56];
const TOTALW = WEIGHT.reduce((a, b) => a + b, 0);
const CENTER = {};
{ let acc = 0; SLOTS.forEach((s, i) => { CENTER[s] = (acc + WEIGHT[i] / 2) / TOTALW * 100; acc += WEIGHT[i]; }); }
const PATH = { full: SLOTS, fast: ['intake', 'analyst', 'gate1', 'builder', 'reviewer', 'gate2', 'done'] };
const NAME = { intake: 'Intake', gate1: 'Gate 1', gate2: 'Gate 2', done: 'Merged' };
const NEXTNOTE = { analyst: 'Stories and acceptance checks', gate1: 'You approve the plan and the lane', architect: 'Design decision and task list', builder: 'Code and tests on a branch', reviewer: 'An independent attempt to break it', qa: 'Full test suite and the merge proposal', gate2: 'You read the card and merge', done: 'On main' };
const WHO = { analyst: 'Analyst', architect: 'Architect', builder: 'Builder', reviewer: 'Reviewer', qa: 'QA', you: 'You', auto: 'Autopilot', gate1: 'Gate 1', gate2: 'Gate 2', github: 'GitHub' };
const WALK = 274, CHAMBER = 220, ARRIVE_MS = 2000;
const LINEUP = 2;   // crates drawn in one queue; a longer queue shows these and a count of the rest. A third would sit on the next queue over.

const ICON = {
  play: 'M8 5.5v13l11-6.5z', pause: 'M8.5 5v14M15.5 5v14',
  sun: 'M12 3v2M12 19v2M3 12h2M19 12h2M5.6 5.6L7 7M17 17l1.4 1.4M5.6 18.4L7 17M17 7l1.4-1.4M12 8a4 4 0 1 0 0 8 4 4 0 0 0 0-8z',
  moon: 'M20 14.5A8.5 8.5 0 0 1 9.5 4 8.5 8.5 0 1 0 20 14.5z',
  inbox: 'M4 13l2.6-7h10.8L20 13M4 13v5a1 1 0 0 0 1 1h14a1 1 0 0 0 1-1v-5M4 13h4.5l1 2.5h5l1-2.5H20',
  user: 'M15 19v-1.5a3.5 3.5 0 0 0-3.5-3.5h-4A3.5 3.5 0 0 0 4 17.5V19M9.5 10.5a3.25 3.25 0 1 0 0-6.5 3.25 3.25 0 0 0 0 6.5zM15.5 11l2 2 3.5-3.5',
  merge: 'M6 9v12M6 9a3 3 0 1 0 0-6 3 3 0 0 0 0 6zM18 21a3 3 0 1 0 0-6 3 3 0 0 0 0 6zM6 9a9 9 0 0 0 9 9',
  file: 'M14 3.5H7.5A1.5 1.5 0 0 0 6 5v14a1.5 1.5 0 0 0 1.5 1.5h9A1.5 1.5 0 0 0 18 19V7.5zM14 3.5v4h4M9 12.5h6M9 16h4',
  search: 'M10.5 17a6.5 6.5 0 1 0 0-13 6.5 6.5 0 0 0 0 13zM20 20l-4.6-4.6',
  term: 'M5 7l5 5-5 5M12.5 17H19',
  pencil: 'M4 20l1-4.5L16.5 4a2.1 2.1 0 0 1 3 3L8 18.5zM14.5 6l3 3',
  msg: 'M20 14.5a2 2 0 0 1-2 2H9l-4.5 4V6a2 2 0 0 1 2-2H18a2 2 0 0 1 2 2z',
  spark: 'M12 3.5l1.9 5.1 5.1 1.9-5.1 1.9L12 17.5l-1.9-5.1L5 10.5l5.1-1.9z',
  eye: 'M2.5 12s3.5-6.5 9.5-6.5 9.5 6.5 9.5 6.5-3.5 6.5-9.5 6.5S2.5 12 2.5 12zM12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6z',
  list: 'M4 6.5l1.5 1.5L8 5.5M4 12.5l1.5 1.5L8 11.5M4 18.5l1.5 1.5L8 17.5M11.5 7H20M11.5 13H20M11.5 19H20',
  plan: 'M4 5.5A1.5 1.5 0 0 1 5.5 4h13A1.5 1.5 0 0 1 20 5.5v13a1.5 1.5 0 0 1-1.5 1.5h-13A1.5 1.5 0 0 1 4 18.5zM4 9.5h16M9.5 9.5V20',
  code: 'M8.5 7.5L4 12l4.5 4.5M15.5 7.5L20 12l-4.5 4.5M13.5 5l-3 14',
  flask: 'M9 3.5h6M10 3.5v5.2L5.2 17a2.3 2.3 0 0 0 2 3.5h9.6a2.3 2.3 0 0 0 2-3.5L14 8.7V3.5M7.6 14.5h8.8',
  tag: 'M4 4.5h7.2l8.3 8.3a1.5 1.5 0 0 1 0 2.1l-4.6 4.6a1.5 1.5 0 0 1-2.1 0L4.5 11.2zM8.5 8.5h.01',
  branch: 'M7 9v6M7 9a2.5 2.5 0 1 0 0-5 2.5 2.5 0 0 0 0 5zM7 20a2.5 2.5 0 1 0 0-5 2.5 2.5 0 0 0 0 5zM17 9a2.5 2.5 0 1 0 0-5 2.5 2.5 0 0 0 0 5zM17 9c0 3.5-3 5-7.5 6',
  pr: 'M6.5 9v6M6.5 9a2.5 2.5 0 1 0 0-5 2.5 2.5 0 0 0 0 5zM6.5 20a2.5 2.5 0 1 0 0-5 2.5 2.5 0 0 0 0 5zM17.5 20a2.5 2.5 0 1 0 0-5 2.5 2.5 0 0 0 0 5zM17.5 15V9.5A2.5 2.5 0 0 0 15 7h-2.5M14.5 4.5L12 7l2.5 2.5',
  okc: 'M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18zM8 12.5l2.7 2.7L16 9.5',
  card: 'M4.5 6.5A1.5 1.5 0 0 1 6 5h12a1.5 1.5 0 0 1 1.5 1.5v11A1.5 1.5 0 0 1 18 19H6a1.5 1.5 0 0 1-1.5-1.5zM8 9.5h8M8 13h5',
  alert: 'M12 4l9 15.5H3zM12 10v4.5M12 17.5h.01',
  shield: 'M12 3l7 2.6v5.6c0 4.3-2.9 7.6-7 9.3-4.1-1.7-7-5-7-9.3V5.6zM9 12l2.2 2.2L15.2 10',
  check: 'M5 12.5l4.5 4.5L19 7.5', chevD: 'M6 9l6 6 6-6', chevR: 'M9 6l6 6-6 6',
  laptop: 'M5.5 5.5h13a1 1 0 0 1 1 1V15h-15V6.5a1 1 0 0 1 1-1zM3 18.5h18',
  lock: 'M7.5 10.5V8a4.5 4.5 0 0 1 9 0v2.5M6 10.5h12a1 1 0 0 1 1 1V19a1 1 0 0 1-1 1H6a1 1 0 0 1-1-1v-7.5a1 1 0 0 1 1-1z',
  ext: 'M14 5h5v5M19 5l-8.5 8.5M17.5 13.5V18a1.5 1.5 0 0 1-1.5 1.5H6A1.5 1.5 0 0 1 4.5 18V8A1.5 1.5 0 0 1 6 6.5h4.5',
  brand: 'M4.5 14.5h15a2.5 2.5 0 0 1 0 5h-15a2.5 2.5 0 0 1 0-5zM7.5 17h.01M12 17h.01M16.5 17h.01M8 14.5v-5h5.5v5M16.5 11h2.5',
  bolt: 'M13 3L5 13.5h6L10.5 21 19 10h-6z'
};
const KIND = { read: ICON.file, search: ICON.search, bash: ICON.term, edit: ICON.pencil, write: ICON.pencil, gh: ICON.msg, think: ICON.spark };

// What the page says about each station. The model, the prompt and every permission chip come from /api/meta (the agent
// files, the guard hook and the lane templates); `rules` are the limits a role's instructions set, which nothing enforces.
const STATION = {
  analyst: { name: 'Product Analyst', short: 'Analyst', icon: ICON.list, start: 'Starts on stage:intake',
    role: 'Turns a request into user stories with pass or fail acceptance checks, and recommends a lane. You choose the lane at Gate 1.',
    boundary: 'Read-only on the repo. It can only comment on issues and move one to gate:stories.', rules: ['Any stage label'] },
  architect: { name: 'Architect', short: 'Architect', icon: ICON.plan, start: 'Starts on stage:design',
    role: 'Writes the design decision and splits the work into tasks, each listing the exact files allowed. Later it checks the pull request matches that design.',
    boundary: 'Writes under docs/ only. It never touches application code and never merges.', rules: ['Writes outside docs/', 'Gate labels'] },
  builder: { name: 'Builder', short: 'Builder', icon: ICON.code, start: 'Starts on stage:build',
    role: 'Writes the code and a test for every acceptance check, on its own branch, then opens a pull request. It never merges.',
    boundary: 'Works on its own feature branch, inside the files the task allows. A scope check stops any commit outside them.', rules: ['Label changes'] },
  reviewer: { name: 'Adversarial Reviewer', short: 'Reviewer', icon: ICON.eye, start: 'Starts on a new pull request',
    role: 'Starts with fresh context, sees only the change, and tries to break it. The Architect then checks the design was followed.',
    boundary: 'Read-only. It can only comment on the pull request. It cannot edit code, change labels or merge.', rules: ['Label changes'] },
  qa: { name: 'QA & Release-Ops', short: 'QA', icon: ICON.flask, start: 'Starts on stage:qa',
    role: 'Runs the full test suite, fills test gaps, does a security pass, and drafts the merge proposal for you.',
    boundary: 'Writes in the test folders only. It never merges, deploys or runs a migration.', rules: ['Deploy', 'Migrations', 'Writes outside test folders'] }
};

// ------------------------------------------------------------------------------------ small helpers
const pad = (v, n) => String(v).padStart(n, '0');
const fTok = v => v >= 1e6 ? (v / 1e6).toFixed(2) + 'M' : v >= 1e4 ? Math.round(v / 1e3) + 'k' : v >= 1e3 ? (v / 1e3).toFixed(1) + 'k' : String(Math.round(v || 0));
const fTokC = v => v >= 1e6 ? (v / 1e6).toFixed(1) + 'M' : fTok(v);
const fUsd = v => '$' + (v >= 100 ? v.toFixed(0) : (v || 0).toFixed(2));
const fDur = s => { s = Math.max(0, Math.round(s)); if (s < 60) return s + 's'; const m = Math.floor(s / 60); return m < 60 ? m + 'm ' + pad(s % 60, 2) + 's' : Math.floor(m / 60) + 'h ' + pad(m % 60, 2) + 'm'; };
const fMin = s => { const m = Math.max(0, Math.round(s / 60)); return m < 60 ? m + 'm' : m < 1440 ? Math.floor(m / 60) + 'h ' + pad(m % 60, 2) + 'm' : Math.floor(m / 1440) + 'd ' + Math.floor(m % 1440 / 60) + 'h'; };
const fClock = t => { const d = new Date(t * 1000); return pad(d.getHours(), 2) + ':' + pad(d.getMinutes(), 2); };
const fClockS = t => fClock(t) + ':' + pad(new Date(t * 1000).getSeconds(), 2);
const plural = (n, one, many) => n + ' ' + (n === 1 ? one : many);
const tf = v => v ? 'true' : 'false';   // for aria-* attributes, which want the word

const ESC = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' };
const esc = v => String(v === null || v === undefined ? '' : v).replace(/[&<>"']/g, c => ESC[c]);
const raw = s => ({ __raw: String(s) });
const put = v => Array.isArray(v) ? v.map(put).join('') : v && v.__raw !== undefined ? v.__raw : v === false || v === null || v === undefined ? '' : esc(v);
// h`...`: every interpolated value is escaped unless it is itself the result of h or raw. Text from GitHub and from agents is untrusted.
function h(strings, ...vals) { let out = strings[0]; vals.forEach((v, i) => { out += put(v) + strings[i + 1]; }); return raw(out); }
const ico = (d, size = 16, sw = 1.9, attrs = '') => raw('<svg width="' + size + '" height="' + size + '" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="' + sw + '" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"' + attrs + '><path d="' + d + '"></path></svg>');
const bolt = size => raw('<svg width="' + size + '" height="' + size + '" viewBox="0 0 24 24" fill="currentColor" stroke="none" aria-hidden="true"><path d="' + ICON.bolt + '"></path></svg>');

// Patch `from` so it matches `to`, keeping existing elements. Children with data-key keep their identity when they move.
const sameKind = (a, b) => a.nodeType === b.nodeType && (a.nodeType !== 1 || a.tagName === b.tagName);
function morph(from, to) {
  if (from.nodeType !== 1) { if (from.nodeValue !== to.nodeValue) from.nodeValue = to.nodeValue; return; }
  for (const a of Array.from(from.attributes)) if (!to.hasAttribute(a.name)) from.removeAttribute(a.name);
  for (const a of Array.from(to.attributes)) if (from.getAttribute(a.name) !== a.value) from.setAttribute(a.name, a.value);
  const keyed = new Map();
  for (const c of Array.from(from.children)) if (c.dataset && c.dataset.key) keyed.set(c.dataset.key, c);
  let cur = from.firstChild;
  for (const t of Array.from(to.childNodes)) {
    const key = t.nodeType === 1 && t.dataset ? t.dataset.key : null;
    let match = null;
    if (key) { match = keyed.get(key) || null; if (match && !sameKind(match, t)) match = null; }
    else if (cur && sameKind(cur, t) && !(cur.nodeType === 1 && cur.dataset && cur.dataset.key)) match = cur;
    if (match) {
      if (match === cur) cur = cur.nextSibling; else from.insertBefore(match, cur);
      morph(match, t);
    } else from.insertBefore(t, cur);
  }
  while (cur) { const next = cur.nextSibling; from.removeChild(cur); cur = next; }
}

// ------------------------------------------------------------------------------------ app state
const params = new URLSearchParams(location.search);
const saved = (() => { try { return JSON.parse(localStorage.getItem('adlc-mc') || '{}'); } catch (e) { return {}; } })();
const A = {
  meta: { stations: [], demo: false }, agents: {}, data: null, at: 0, demo: null, source: null, lost: false, trouble: '',
  pool: [], seen: new Map(), arr: new Map(), frozenAt: null,
  ui: { sel: { type: 'station', id: 'builder' }, tab: 'live', left: 'work', ctx: 'agent', lane: 'all', theme: saved.theme || null, pal: saved.pal || 'cool',
    playing: true, repoMenu: false, hov: null, closed: new Set(), toast: null, repo: params.get('repo') || saved.repo || '' }
};
const save = () => { try { localStorage.setItem('adlc-mc', JSON.stringify({ theme: A.ui.theme, pal: A.ui.pal, repo: A.ui.repo })); } catch (e) { /* private window */ } };
const clock = () => !A.data ? Date.now() / 1000 : A.frozenAt !== null ? A.frozenAt : A.data.mode === 'demo' ? A.data.now : A.data.now + (performance.now() - A.at) / 1000;

const hueOf = r => r.phase === 'waiting' ? 'h-you' : r.phase === 'done' ? 'h-done' : STATION[r.at] ? 'h-' + r.at : 'h-none';
// 'queued' only says that no run on this machine is working on the request. Its agent may be at work on GitHub, out of sight,
// so the page says where the request is and stops short of calling it queued or idle.
const whereOf = (r, now) => (r.phase === 'working' ? STATION[r.at].short + ', working' : r.phase === 'queued' ? 'At the ' + STATION[r.at].short
  : r.phase === 'waiting' ? NAME[r.at] + ', ' + fMin(now - r.since) : r.phase === 'done' ? 'Merged' : 'Intake') + (r.alert ? '. ' + r.alert : '');

const stationWord = (live, n) => live ? 'Working' + (n ? ', ' + n + ' more here' : '') : n ? plural(n, 'request', 'requests') + ' here, no run on this machine' : 'Idle';

// ------------------------------------------------------------------------------------ templates
function topBar(D, U, waiting) {
  const status = D.mode === 'demo' ? ['', 'Demo data. Nothing here is real'] : !D.repo ? ['is-warn', 'No GitHub repo found here'] : D.github.ok ? ['is-live', 'Following GitHub labels'] : ['is-warn', 'GitHub could not be read'];
  const read = D.github.polled ? 'Last read from GitHub at ' + fClockS(D.github.polled) + '. ' : '';
  const title = D.mode === 'demo' ? 'Simulated requests, timings and token counts' : D.github.ok ? read + 'Agents report here when they run on this machine' : read + D.github.msg;
  return h`<header class="mc-top" style="flex: none; height: 54px; display: flex; align-items: center; gap: 10px">
<div style="display: flex; align-items: center; gap: 10px; margin-right: 6px">
<div style="width: 30px; height: 30px; border-radius: 9px; background: var(--ink); color: var(--page); display: flex; align-items: center; justify-content: center; flex: none">${ico(ICON.brand, 18)}</div>
<div style="font-size: 15px; font-weight: 650; letter-spacing: -0.015em; white-space: nowrap">Mission Control</div>
</div>
<div style="position: relative">
<button class="b0 pillbtn" data-act="repoMenu" aria-haspopup="true" aria-expanded="${tf(U.repoMenu)}"><span class="mono" style="font-size: 12.5px">${D.repo || 'No repo'}</span>${ico(ICON.chevD, 13, 2.2)}</button>
${U.repoMenu ? h`<div style="position: absolute; top: 40px; left: 0; z-index: 40; width: 300px; padding: 6px; border-radius: 14px; background: var(--surface); border: 1px solid var(--line); box-shadow: var(--shadow)">
<div style="padding: 6px 10px 4px; color: var(--ink-3); font-size: 11.5px">Repositories that use the plugin</div>
${D.repos.length ? D.repos.map(r => h`<button class="b0 row" data-act="repo" data-arg="${r.name}">
<span class="mono ell" style="flex: 1; min-width: 0; font-size: 12.5px">${r.name}</span>
<span class="tnum" style="color: var(--ink-3); font-size: 12px">${r.count} on the line</span>
<span style="width: 16px; height: 16px; display: flex; flex: none">${r.name === D.repo ? ico(ICON.check, 16, 2.4) : ''}</span>
</button>`) : h`<div class="empty">No repo yet. Start Mission Control inside a repo, or pass --repo owner/name.</div>`}
</div>` : ''}
</div>
<div style="display: flex; align-items: center; gap: 8px; padding: 0 6px; color: var(--ink-2); white-space: nowrap" title="${title}"><span class="andon ${status[0]}"></span><span>${status[1]}</span></div>
<div style="flex: 1"></div>
<button class="b0 pillbtn ${waiting.length ? 'is-warn' : ''}" data-act="waiting">${ico(ICON.user, 15, 2)}<span style="white-space: nowrap">${waiting.length ? waiting.length + ' waiting on you' : 'Nothing is waiting on you'}</span></button>
<div class="seg" role="group" aria-label="Lane filter">
${[['all', 'All lanes'], ['full', 'Full'], ['fast', 'Fast']].map(x => h`<button class="b0 seg-b ${U.lane === x[0] ? 'is-on' : ''}" aria-pressed="${tf(U.lane === x[0])}" data-act="lane" data-arg="${x[0]}">${x[1]}</button>`)}
</div>
<button class="b0 iconbtn" data-act="play" aria-label="${U.playing ? 'Pause the live view' : 'Resume the live view'}" title="${U.playing ? 'Pause the live view' : 'Resume the live view'}">${ico(U.playing ? ICON.pause : ICON.play, 16, 2)}</button>
<button class="b0 iconbtn" data-act="theme" aria-label="${U.dark ? 'Switch to light' : 'Switch to dark'}" title="${U.dark ? 'Switch to light' : 'Switch to dark'}">${ico(U.dark ? ICON.sun : ICON.moon, 16)}</button>
</header>`;
}

function machine(slot, flex, D, U, now) {
  const st = STATION[slot], sd = D.stations[slot] || { today: {}, run: null, queued: 0 }, run = sd.run;
  const here = D.requests.filter(r => r.at === slot);
  const act = here.find(r => r.phase === 'working') || null;
  const live = !!act || !!(run && run.live);
  const mine = run && run.live && (!act || run.n === act.n || run.n === null) ? run : null;
  const sel = U.sel.type === 'station' && U.sel.id === slot;
  const agent = A.agents[slot] || {};
  let label = '', step = 'Working', meta = '', pct = null;
  if (live) {
    label = act ? '#' + act.n + ' ' + act.title : run.n ? '#' + run.n + ' ' + run.title : 'A run with no issue number';
    if (mine) {
      const open = mine.steps.filter(s => s.t1 === null), last = open.length ? open[open.length - 1] : mine.steps[mine.steps.length - 1];
      if (last) step = last.label;
      meta = (mine.total ? 'Step ' + Math.min(mine.stepCount, mine.total) + ' of ' + mine.total : plural(mine.stepCount, 'step', 'steps')) + ', ' + fDur(now - mine.t0);
      pct = mine.total ? Math.min(1, mine.steps.filter(s => s.t1 !== null).length / mine.total) : null;
    } else meta = fDur(now - act.since);
  }
  const t = sd.today || {}, noTel = !D.telemetry;
  const metrics = [[noTel ? '—' : fTokC(t.tok || 0), 'tokens'], [noTel ? '—' : fUsd(t.usd || 0), 'cost'], [sd.lat === null || sd.lat === undefined ? '—' : sd.lat.toFixed(1) + 's', 'latency']];
  return h`<div style="position: relative; flex: ${flex}; min-width: 0; padding: 0 5px">
<div class="mach h-${slot} ${live ? 'is-working' : 'is-idle'} ${sel ? 'is-sel' : ''}" style="margin-top: 16px; height: 240px; display: flex; flex-direction: column">
<button class="b0 bay-hit" data-act="station" data-arg="${slot}" aria-label="Open the ${st.name} station" aria-pressed="${tf(sel)}"></button>
<span class="tower" title="${stationWord(live, sd.queued)}"><span class="lamp ${here.some(r => r.alert) ? 'is-red' : ''}"></span><span class="lamp ${sd.queued ? 'is-amber' : ''}"></span><span class="lamp ${live ? 'is-green' : ''}"></span></span>
<div class="mach-stripe"></div>
<div style="display: flex; align-items: center; gap: 8px; padding: 8px 10px 0; pointer-events: none">
<div class="av" style="width: 30px; height: 30px; border-radius: 9px; display: flex; align-items: center; justify-content: center; flex: none">${ico(st.icon, 16, 2)}</div>
<div style="min-width: 0; flex: 1">
<div class="ell" style="font-weight: 650; font-size: 13px; letter-spacing: -0.01em; line-height: 1.25">${st.short}</div>
<div class="ell" style="color: var(--ink-3); font-size: 11px; line-height: 1.25">${(run && run.model) || agent.model || ''}</div>
</div>
</div>
<div class="screen" style="margin: 6px 8px 0; height: 72px; padding: 7px 9px 6px; display: flex; flex-direction: column; pointer-events: none">
${live ? h`<button class="b0 issue-link ell" data-act="issue" data-arg="${act ? act.n : run.n || ''}" style="pointer-events: auto; display: block; flex: none; max-width: 100%; color: var(--screen-ink); font-weight: 600; font-size: 12px; line-height: 1.3">${label}</button>
<div style="display: flex; align-items: center; gap: 5px; min-width: 0; margin-top: 1px; color: var(--screen-ink-2); font-size: 11.5px; line-height: 1.3"><span class="spinner"></span><span class="ell">${step}</span></div>
<div style="margin-top: auto">
<div class="meter ${pct === null ? 'is-open' : ''}"><div class="meter-fill" style="width: ${pct === null ? 38 : (pct * 100).toFixed(1)}%"></div></div>
<div class="tnum" style="display: flex; justify-content: space-between; gap: 6px; margin-top: 4px; color: var(--screen-ink-3); font-size: 10.5px; line-height: 1.2"><span class="ell">${meta}</span><span style="flex: none">${sd.queued ? sd.queued + ' more here' : ''}</span></div>
</div>` : h`<div style="color: var(--screen-ink-2); font-weight: 600; font-size: 12px; line-height: 1.3">${sd.queued ? plural(sd.queued, 'request', 'requests') + ' here' : 'Idle'}</div>
<div style="margin-top: 1px; color: var(--screen-ink-3); font-size: 11.5px; line-height: 1.3">${sd.queued ? 'No run on this machine' : st.start}</div>`}
</div>
<div title="Today at this station" style="display: flex; gap: 4px; margin: 7px 8px 0; pointer-events: none">
${metrics.map(m => h`<div class="plate"><div class="tnum ell" style="font-weight: 650; font-size: 11.5px; letter-spacing: -0.02em; line-height: 1.25">${m[0]}</div><div class="ell" style="color: var(--ink-3); font-size: 9.5px; line-height: 1.25">${m[1]}</div></div>`)}
</div>
<div class="chamber" style="margin: 8px 12px 0; height: 58px; pointer-events: none"><span class="chamber-light"></span><span class="chamber-belt"></span></div>
</div>
</div>`;
}

function gate(slot, flex, D, now) {
  const w = D.requests.filter(r => r.at === slot && r.phase === 'waiting').sort((a, b) => a.since - b.since);
  return h`<div style="position: relative; flex: ${flex}; min-width: 0; padding: 0 5px">
<div class="gatebooth ${w.length ? 'is-waiting' : ''}" style="position: relative; margin-top: 34px; height: 138px; padding: 10px 6px 8px; display: flex; flex-direction: column; align-items: center; gap: 2px; text-align: center">
<button class="b0 bay-hit" data-act="gate" data-arg="${slot}" aria-label="${NAME[slot]}, ${w.length ? w.length + ' waiting on you' : 'clear'}"></button>
<div class="gate-av" style="width: 30px; height: 30px; border-radius: 50%; display: flex; align-items: center; justify-content: center; margin-bottom: 4px; pointer-events: none">${ico(ICON.user, 16)}</div>
<div style="font-weight: 650; font-size: 13px; letter-spacing: -0.01em; line-height: 1.25; pointer-events: none">${NAME[slot]}</div>
<div style="color: var(--ink-3); font-size: 11px; line-height: 1.25; pointer-events: none">${slot === 'gate1' ? 'Plan approval' : 'Merge'}</div>
<div style="flex: 1"></div>
<div class="gate-state tnum" style="pointer-events: none">${w.length ? w.length + ' waiting' : 'Clear'}</div>
<div class="tnum" style="color: var(--ink-3); font-size: 10.5px; pointer-events: none">${w.length ? 'for ' + fMin(now - w[0].since) : 'Yours to decide'}</div>
</div>
<div style="position: absolute; left: calc(50% - 1.5px); top: 172px; width: 3px; height: 92px; background: var(--steel)"></div>
<div style="position: absolute; left: calc(50% - 4px); top: 264px; width: 8px; height: 58px; border-radius: 3px 3px 0 0; background: var(--steel-2)"></div>
<div class="boom ${w.length ? '' : 'is-up'}" style="position: absolute; left: calc(50% - 48px); top: 266px; width: 48px; height: 9px"></div>
<div style="position: absolute; left: calc(50% - 6px); top: 264.5px; width: 12px; height: 12px; border-radius: 50%; background: var(--warn); border: 3px solid var(--steel-2)"></div>
</div>`;
}

function dock(slot, flex, D) {
  const filing = D.requests.filter(r => r.at === 'intake').length;
  const sub = slot === 'intake' ? (filing ? filing + ' being filed' : 'New requests') : D.merged + ' today';
  return h`<div style="position: relative; flex: ${flex}; min-width: 0; padding: 0 5px">
<div style="margin-top: 44px; display: flex; flex-direction: column; align-items: center; gap: 3px; text-align: center">
<div style="width: 34px; height: 34px; border-radius: 11px; background: var(--surface-2); color: var(--ink-2); display: flex; align-items: center; justify-content: center; margin-bottom: 4px">${ico(slot === 'intake' ? ICON.inbox : ICON.merge, 17)}</div>
<div style="font-weight: 650; font-size: 13px; letter-spacing: -0.01em">${NAME[slot]}</div>
<div class="tnum" style="color: var(--ink-3); font-size: 11px; line-height: 1.3">${sub}</div>
</div>
<div style="position: absolute; left: calc(50% - 36px); top: 288px; width: 72px; height: 6px; border-radius: 3px; background: var(--steel)"></div>
<div style="position: absolute; left: calc(50% - 28px); top: 294px; width: 4px; height: 28px; background: var(--steel-2)"></div>
<div style="position: absolute; left: calc(50% + 24px); top: 294px; width: 4px; height: 28px; background: var(--steel-2)"></div>
</div>`;
}

// Every request is one crate. A crate keeps its element (a slot in the pool) while its request is on the line, so a move
// between stations animates. The pool grows with the line; a queue longer than LINEUP shows its first crates and a count.
function units(D, U, now) {
  const live = new Set(D.requests.map(r => r.n)), t = performance.now();
  A.pool.forEach((n, i) => { if (n !== null && !live.has(n)) { A.pool[i] = null; A.seen.delete(n); A.arr.delete(n); } });
  D.requests.forEach(r => {
    if (!A.pool.includes(r.n)) { const free = A.pool.indexOf(null); if (free >= 0) A.pool[free] = r.n; else A.pool.push(r.n); }
    const was = A.seen.get(r.n), is = r.at + '|' + (r.phase === 'working' ? 'w' : 'o');
    if (was !== undefined && was !== is && r.phase !== 'filing') A.arr.set(r.n, t);
    A.seen.set(r.n, is);
  });
  while (A.pool.length && A.pool[A.pool.length - 1] === null) A.pool.pop();
  const byN = new Map(D.requests.map(r => [r.n, r]));
  const arriving = r => A.arr.has(r.n) && t - A.arr.get(r.n) < ARRIVE_MS;
  const spot = r => r.phase === 'working' ? (arriving(r) ? 'walk' : 'chamber') : r.phase;
  const groups = {};
  D.requests.forEach(r => { const k = r.at + '|' + spot(r); (groups[k] = groups[k] || []).push(r); });
  Object.values(groups).forEach(g => g.sort((a, b) => a.phase === 'done' ? (a.doneAt || 0) - (b.doneAt || 0) : a.since - b.since));
  return A.pool.map((n, i) => {
    const r = n === null ? null : byN.get(n);
    if (!r) return h`<button class="b0 unit is-hidden h-none wh-none" data-key="u${i}" style="left: ${CENTER.intake.toFixed(2)}%; top: ${WALK}px" tabindex="-1" aria-hidden="true"><span class="crate"></span>${worker()}</button>`;
    const sp = spot(r), group = groups[r.at + '|' + sp], k = group.indexOf(r), walk = arriving(r), st = STATION[r.at];
    const lined = sp === 'queued' || sp === 'waiting', place = lined ? Math.min(k, LINEUP - 1) : k;
    const behind = lined && k >= LINEUP, more = lined && k === LINEUP - 1 ? group.length - LINEUP : 0;
    let off = 0, top = WALK, cls = '', wh = st ? 'wh-' + r.at : 'wh-none';
    if (sp === 'chamber') { top = CHAMBER; cls = 'in-chamber'; }
    else if (sp === 'walk') cls = 'on-walk';
    else if (sp === 'queued') { off = -64 - 62 * place; cls = 'on-walk'; }
    else if (sp === 'waiting') { off = -80 - 62 * place; cls = 'on-walk'; wh = 'wh-you'; }
    else if (sp === 'done') { top = WALK - 28 * Math.min(k, 2); cls = walk ? 'on-walk' : ''; wh = 'wh-done'; }
    const sel = U.sel.type === 'issue' && U.sel.n === r.n, dim = U.lane !== 'all' && r.lane !== U.lane;
    const where = whereOf(r, now) + (more ? ', and ' + more + ' more behind it' : '');
    // A crate past the end of the line-up waits unseen behind the last one drawn; the work list still shows it.
    if (behind) return h`<button class="b0 unit is-hidden ${hueOf(r)} ${wh}" data-key="u${i}" style="left: calc(${CENTER[r.at].toFixed(2)}% + ${off}px); top: ${top}px" tabindex="-1" aria-hidden="true"><span class="crate"><span class="tnum">#${r.n}</span></span>${worker()}</button>`;
    return h`<button class="b0 unit ${hueOf(r)} ${wh} is-${r.phase} ${cls} ${walk && sp !== 'filing' ? 'is-walking' : ''} ${sel ? 'is-sel' : ''} ${dim ? 'is-dim' : ''}" data-key="u${i}" style="left: calc(${CENTER[r.at].toFixed(2)}% + ${off}px); top: ${top}px" data-act="issue" data-arg="${r.n}" title="${r.title} (${where})" aria-label="Issue ${r.n}, ${r.title}, ${where}"><span class="crate"><span class="tnum">#${r.n}</span>${r.lane === 'fast' ? bolt(10) : ''}</span>${more ? h`<span class="more tnum">+${more}</span>` : ''}${worker()}</button>`;
  });
}
const worker = () => raw('<svg class="worker" width="36" height="46" viewBox="0 0 36 46" fill="none" aria-hidden="true"><path d="M11 27L8 13M25 27L28 13" stroke="currentColor" stroke-width="2.4" stroke-linecap="round"></path><rect x="10" y="22" width="16" height="16" rx="7" fill="currentColor"></rect><path class="hat" d="M9.5 24a8.5 8.5 0 0 1 17 0z"></path><rect class="hat" x="7.5" y="23" width="21" height="2.6" rx="1.3"></rect><circle class="eye" cx="15.2" cy="30.4" r="1.35"></circle><circle class="eye" cx="20.8" cy="30.4" r="1.35"></circle><path class="leg leg-a" d="M15.5 37.5V44.5" stroke="currentColor" stroke-width="2.4" stroke-linecap="round"></path><path class="leg leg-b" d="M20.5 37.5V44.5" stroke="currentColor" stroke-width="2.4" stroke-linecap="round"></path></svg>');

function line(D, U, now) {
  const onLine = D.requests.filter(r => r.phase !== 'done').length;
  const T = STATIONS.reduce((a, s) => { const t = (D.stations[s] || {}).today || {}; a.usd += t.usd || 0; a.tok += t.tok || 0; a.cr += t.cacheRead || 0; a.inp += t.input || 0; return a; }, { usd: 0, tok: 0, cr: 0, inp: 0 });
  const tel = D.telemetry;
  const kpis = [[tel ? fUsd(T.usd) : '—', 'Spent today'], [tel ? fTok(T.tok) : '—', 'Tokens today'], [tel && T.cr + T.inp ? Math.round(100 * T.cr / (T.cr + T.inp)) + '%' : '—', 'Input from cache'],
    [D.lead ? fMin(D.lead) : '—', 'Request to ready PR']];
  return h`<section aria-label="Assembly line" style="flex: none; display: flex; flex-direction: column; gap: 11px; padding: 14px 12px 4px; background: var(--surface); border: 1px solid var(--line); border-radius: 24px; box-shadow: var(--shadow)">
<div class="mc-linehead" style="display: flex; align-items: flex-end; gap: 16px; padding: 0 10px">
<div style="min-width: 0">
<h1 style="margin: 0; font-size: 22px; font-weight: 680; letter-spacing: -0.025em; line-height: 1.15">Assembly line</h1>
<div style="color: var(--ink-3); margin-top: 3px">${plural(onLine, 'request', 'requests')} on the line. A label change in GitHub starts the next agent. Station figures are today’s totals${tel ? '' : ', and appear once telemetry is on'}.</div>
</div>
<div style="flex: 1"></div>
<div style="display: flex; gap: 30px; flex-wrap: wrap">
${kpis.map(k => h`<div style="min-width: 80px"><div style="font-size: 19px; font-weight: 680; letter-spacing: -0.02em; line-height: 1.2">${k[0]}</div><div style="color: var(--ink-3); font-size: 11.5px">${k[1]}</div></div>`)}
</div>
</div>
<div class="scroll" style="overflow-x: auto; overflow-y: hidden">
<div style="position: relative; min-width: 1180px; height: 328px">
<div style="display: flex; align-items: stretch; height: 328px">
${SLOTS.map((slot, i) => { const flex = WEIGHT[i] + ' 1 0'; return STATION[slot] ? machine(slot, flex, D, U, now) : slot === 'gate1' || slot === 'gate2' ? gate(slot, flex, D, now) : dock(slot, flex, D); })}
</div>
<div class="rail" style="position: absolute; left: 1%; right: 1%; top: 322px; height: 2px"></div>
<div class="fasttag" style="left: 36.34%; top: 311px">${bolt(10)}<span>Fast lane walks past</span></div>
<div class="fasttag" style="left: 77.32%; top: 311px">${bolt(10)}<span>Fast lane walks past</span></div>
${units(D, U, now)}
</div>
</div>
</section>`;
}

function leftPanel(D, U, now) {
  const shown = D.requests.filter(r => U.lane === 'all' || r.lane === U.lane);
  const groups = D.epics.map(e => ({ e, rows: shown.filter(r => r.epic === e.key).sort((a, b) => SLOTS.indexOf(b.at) - SLOTS.indexOf(a.at) || a.n - b.n) })).filter(g => g.rows.length);
  const work = () => groups.length ? groups.map(g => { const open = !U.closed.has(g.e.key); return h`<div style="margin-bottom: 4px">
<button class="b0 grouphead" data-act="epic" data-arg="${g.e.key}" aria-expanded="${tf(open)}">${ico(ICON.chevR, 13, 2.2, ' style="transform: rotate(' + (open ? 90 : 0) + 'deg); transition: transform .18s ease"')}<span>${g.e.name}</span><span class="tnum" style="color: var(--ink-3); font-weight: 500">${g.rows.length}</span></button>
${open ? g.rows.map(r => { const sel = U.sel.type === 'issue' && U.sel.n === r.n; return h`<button class="b0 row ${sel ? 'is-sel' : ''}" data-act="issue" data-arg="${r.n}" aria-pressed="${tf(sel)}">
<span class="sdot ${hueOf(r)}"></span>
<span class="tnum" style="flex: none; width: 38px; color: var(--ink-3); font-size: 12px">#${r.n}</span>
<span class="ell" style="flex: 1; min-width: 0; font-weight: 500">${r.title}</span>
${r.lane === 'fast' ? h`<span class="chip" title="Fast lane">${bolt(10)}Fast</span>` : ''}
<span class="tnum ell" style="flex: none; max-width: 150px; color: var(--ink-2); font-size: 12px">${whereOf(r, now)}</span>
</button>`; }) : ''}
</div>`; }) : h`<div class="empty">${D.requests.length ? 'No requests in this lane right now.' : 'Nothing is on the line. Label an issue stage:intake, or run /adlc-intake, and it shows up here.'}</div>`;
  const feed = () => D.feed.length ? D.feed.map(f => h`<button class="b0 row" data-act="issue" data-arg="${f.n === null || f.n === undefined ? '' : f.n}" style="align-items: flex-start; gap: 9px; min-height: 0; padding: 8px 10px">
<span class="tnum" style="flex: none; width: 36px; padding-top: 1px; color: var(--ink-3); font-size: 11.5px">${fClock(f.t)}</span>
<span class="sdot ${STATION[f.who] ? 'h-' + f.who : f.who === 'gate1' || f.who === 'gate2' ? 'h-you' : 'h-none'}" style="margin-top: 5px"></span>
<span style="flex: 1; min-width: 0; color: var(--ink-2); line-height: 1.4"><span style="color: var(--ink); font-weight: 600">${WHO[f.who] || f.who}</span> ${f.text}</span>
</button>`) : h`<div class="empty">Nothing has happened yet today.</div>`;
  return h`<section class="mc-left panel" aria-label="Work" style="flex: 0 0 388px; min-width: 0; display: flex; flex-direction: column">
<div role="tablist" aria-label="Work views" style="flex: none; display: flex; align-items: center; gap: 2px; padding: 10px 10px 8px; border-bottom: 1px solid var(--line)">
<button class="b0 tab ${U.left === 'work' ? 'is-on' : ''}" role="tab" aria-selected="${tf(U.left === 'work')}" data-act="left" data-arg="work">On the line<span class="count tnum">${shown.length}</span></button>
<button class="b0 tab ${U.left === 'feed' ? 'is-on' : ''}" role="tab" aria-selected="${tf(U.left === 'feed')}" data-act="left" data-arg="feed">Activity</button>
</div>
<div class="scroll" data-scroll="left" style="flex: 1; min-height: 0; padding: 8px">${U.left === 'work' ? work() : feed()}</div>
</section>`;
}

function stationPanel(D, U, now) {
  const id = U.sel.id, st = STATION[id], sd = D.stations[id] || { today: {}, run: null, queued: 0 }, run = sd.run, agent = A.agents[id] || {};
  const act = D.requests.find(r => r.at === id && r.phase === 'working'), live = !!act || !!(run && run.live);
  const tabs = [['live', 'Live'], ['input', 'Input'], ['output', 'Output'], ['telemetry', 'Telemetry']];
  const pane = U.tab === 'live' ? liveTab(st, run, now) : U.tab === 'input' ? inputTab(st, run, agent, U) : U.tab === 'output' ? outputTab(run) : telemetryTab(D, sd, run, U, now);
  return h`<div class="h-${id}" style="flex: 1; min-height: 0; display: flex; flex-direction: column">
<div style="flex: none; padding: 16px 18px 0; display: flex; flex-direction: column; gap: 11px">
<div style="display: flex; align-items: flex-start; gap: 12px">
<div class="av" style="width: 44px; height: 44px; border-radius: 14px; display: flex; align-items: center; justify-content: center; flex: none">${ico(st.icon, 22, 1.8)}</div>
<div style="flex: 1; min-width: 0">
<div style="display: flex; align-items: center; gap: 9px; flex-wrap: wrap">
<h2 style="margin: 0; font-size: 18px; font-weight: 680; letter-spacing: -0.02em">${st.name}</h2>
<span class="status ${live ? 'is-on' : ''}"><span class="andon ${live ? 'is-on' : ''}"></span>${stationWord(live, sd.queued)}</span>
<span style="flex: 1"></span>
${run && run.n ? h`<button class="b0 chip chip-link" data-act="issue" data-arg="${run.n}" style="height: 24px"><span class="ell">${run.live ? 'Now' : 'Last'}: #${run.n} ${run.title}</span></button>` : ''}
</div>
<div style="margin-top: 3px; max-width: 72ch; color: var(--ink-2); text-wrap: pretty">${st.role}</div>
</div>
</div>
<div style="display: flex; align-items: center; gap: 6px 12px; flex-wrap: wrap; padding-bottom: 8px; border-bottom: 1px solid var(--line)">
<div role="tablist" aria-label="Station views" style="display: flex; gap: 2px">
${tabs.map(t => h`<button class="b0 tab ${U.tab === t[0] ? 'is-on' : ''}" role="tab" aria-selected="${tf(U.tab === t[0])}" data-act="tab" data-arg="${t[0]}">${t[1]}</button>`)}
</div>
<span style="flex: 1"></span>
<div style="display: flex; gap: 6px; flex-wrap: wrap">
<span class="chip">Model: ${(run && run.model) || agent.model || 'not set'}</span>
<span class="chip" title="A run on another machine, such as a lane on GitHub, shows its results but not its steps">${ico(ICON.laptop, 12, 2)}Shows runs on this machine</span>
<span class="chip">${ico(ICON.tag, 12, 2)}${st.start}</span>
</div>
</div>
</div>
<div class="scroll" data-scroll="right" style="flex: 1; min-height: 0; padding: 12px 18px 18px">${pane}</div>
</div>`;
}

const noRun = st => h`<div class="hint"><b>No run seen yet.</b> ${st.start}. When this agent runs on this machine, its steps show up here as they happen.</div>`;

function liveTab(st, run, now) {
  if (!run) return noRun(st);
  const rows = run.steps.slice(-60).reverse(), hasTok = rows.some(s => s.tok !== null && s.tok !== undefined);
  return h`<div class="tnum" style="display: flex; align-items: center; gap: 10px; padding: 0 8px 8px; color: var(--ink-3); font-size: 12px">
<span class="ell" style="flex: 1; min-width: 0">${run.live ? 'Run' : 'Last run'}${run.n ? ' for #' + run.n : ''}${run.round ? ', fix round ' + run.round : ''}. Started ${fClock(run.t0)}${run.t1 ? ', finished ' + fClock(run.t1) : ''}, session ${run.session}</span>
<span style="flex: none; width: 62px; text-align: right">Time</span>
${hasTok ? h`<span style="flex: none; width: 66px; text-align: right">Tokens</span>` : ''}
</div>
${rows.length ? h`<ol style="list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 2px">
${rows.map(s => { const open = s.t1 === null && run.live; return h`<li class="step ${open ? 'is-now' : ''}">
<span class="stepico">${ico(s.ok === false ? ICON.alert : KIND[s.kind] || ICON.spark, 14, 2)}</span>
<span class="ell" style="flex: 1; min-width: 0">${s.label}</span>
<span class="tnum" style="flex: none; width: 62px; text-align: right; color: var(--ink-3); font-size: 12px">${fDur((s.t1 === null ? (run.live ? now : s.t0) : s.t1) - s.t0)}</span>
${hasTok ? h`<span class="tnum" style="flex: none; width: 66px; text-align: right; color: var(--ink-3); font-size: 12px">${open ? 'running' : s.tok === null || s.tok === undefined ? '' : fTok(s.tok)}</span>` : ''}
</li>`; })}
</ol>` : h`<div class="hint">The run has started. No tool call yet.</div>`}
<div style="display: flex; align-items: flex-start; gap: 9px; margin-top: 12px; padding: 9px 12px; border-radius: 12px; background: var(--surface-2); color: var(--ink-2)">${ico(ICON.lock, 14, 2, ' style="flex: none; margin-top: 2px"')}<span style="text-wrap: pretty">${st.boundary}</span></div>`;
}

function inputTab(st, run, agent, U) {
  if (!run) return noRun(st);
  const parts = run.ctx || [];
  const note = run.prefixNote || (run.ctxTotal ? 'Sizes marked ~ are estimates from file sizes. The rest is measured.' : 'Sizes are estimates from file sizes. Measured sizes appear once telemetry is on.');
  return h`<div style="display: flex; flex-direction: column; gap: 20px">
<div>
<div style="display: flex; align-items: baseline; gap: 12px; flex-wrap: wrap; margin-bottom: 9px">
<h3 class="h3">Context window</h3>
<span class="tnum" style="color: var(--ink-3); font-size: 12px">${run.ctxTotal ? fTok(run.ctxTotal) + ' tokens in the latest request' : ''}</span>
<span style="flex: 1"></span>
<span class="legend"><span class="sw pc"></span>Served from cache</span>
<span class="legend"><span class="sw pn"></span>New input</span>
</div>
<div style="display: flex; gap: 2px; height: 22px">
${parts.map(c => h`<button class="b0 part ${c.cached ? 'pc' : 'pn'} ${U.ctx === c.id ? 'is-open' : ''}" style="flex: ${Math.max(1, c.tok)} 1 0; min-width: 5px" data-act="ctx" data-arg="${c.id}" title="${c.name}, ${c.est ? 'about ' : ''}${fTok(c.tok)} tokens" aria-label="${c.name}, ${c.est ? 'about ' : ''}${fTok(c.tok)} tokens, ${c.cached ? 'cached' : 'new'}"></button>`)}
</div>
<div class="tnum" style="margin-top: 10px; padding: 0 8px; color: var(--ink-3); font-size: 12px; text-wrap: pretty">${note}</div>
<div style="display: flex; flex-direction: column; margin-top: 4px">
${parts.map(c => { const open = U.ctx === c.id; return h`<button class="b0 row ${open ? 'is-sel' : ''}" data-act="ctx" data-arg="${c.id}" aria-expanded="${tf(open)}">
<span class="sw ${c.cached ? 'pc' : 'pn'}"></span>
<span class="ell" style="flex: 1; min-width: 0; font-weight: 500">${c.name}</span>
<span style="flex: none; color: var(--ink-3); font-size: 12px">${c.cached ? 'cached' : 'new'}</span>
<span class="tnum" style="flex: none; width: 58px; text-align: right; color: var(--ink-2)">${c.est ? '~' : ''}${fTok(c.tok)}</span>
</button>
${open ? h`<div style="margin: 2px 8px 8px 28px; padding: 10px 12px; border-radius: 12px; background: var(--surface-2); color: var(--ink-2)">
<div style="text-wrap: pretty">${c.detail}</div>
${(c.items || []).map(it => h`<div style="display: flex; gap: 10px; margin-top: 6px"><span class="mono ell" style="flex: 1; min-width: 0; font-size: 11.5px">${it.name}</span><span class="tnum" style="flex: none; color: var(--ink-3); font-size: 12px">${it.tok === null || it.tok === undefined ? '' : fTok(it.tok)}</span></div>`)}
${c.text ? h`<pre class="code scroll" style="margin-top: 10px; max-height: 240px; background: var(--surface)">${c.text}</pre>` : ''}
</div>` : ''}`; })}
</div>
</div>
<div><h3 class="h3" style="margin-bottom: 8px">Task prompt</h3><pre class="code">${run.prompt || 'The task prompt was not captured for this run.'}</pre></div>
<div><h3 class="h3" style="margin-bottom: 8px">Trigger payload</h3><pre class="code">${JSON.stringify(run.payload || {}, null, 2)}</pre></div>
<div>
<h3 class="h3">Permissions</h3>
${permissions(agent, st)}
</div>
</div>`;
}

// What the agent may run, row by row. "Local run": the agent file's tools, with the guard hook's command limits in place
// of a bare Bash. "Actions lane": that lane's own grant, which can be narrower. Then what the guard and the tool grant
// block, and what the role's instructions add on top. All of it comes from /api/meta; nothing here is typed in.
function permissions(agent, st) {
  const row = (label, chips, cls = 'chip mono', icon = null) => h`<div style="margin-top: 8px"><div style="font-size: 11px; color: var(--ink-3)">${label}</div>
<div style="display: flex; flex-wrap: wrap; gap: 6px; margin-top: 4px">${chips.map(t => h`<span class="${cls}">${icon ? ico(icon, 11, 2.1) : ''}${t}</span>`)}</div></div>`;
  const groups = [];   // lanes with the same grant share one row
  (agent.lanes || []).forEach(l => { const key = l.tools.join(','); const g = groups.find(x => x.key === key); if (g) g.lanes.push(l.lane); else groups.push({ key, lanes: [l.lane], tools: l.tools }); });
  return h`${agent.guard === 'missing' ? h`<div class="chip chip-no" style="height: auto; padding: 6px 8px; margin-top: 8px; white-space: normal">${ico(ICON.alert, 11, 2.1)}The plugin's guard hook could not be read. The list below is the agent file's tools line as written; what this agent may run through Bash is unknown here.</div>` : ''}
${row('Local run', agent.tools || [])}
${groups.map(g => row('Actions lane' + (g.lanes.length > 1 ? 's: ' : ': ') + g.lanes.join(', '), g.tools))}
${(agent.blocked || []).length ? row('Blocked by the guard and the tool grant', agent.blocked, 'chip chip-no', ICON.lock) : ''}
${st.rules.length ? row('By its instructions', st.rules, 'chip chip-no', ICON.lock) : ''}`;
}

function outputTab(run) {
  if (!run) return h`<div class="hint"><b>No run seen yet.</b> What this station hands off shows up here.</div>`;
  const items = run.outputs || [];
  const headline = run.headline || (run.live ? (items.length ? plural(items.length, 'output', 'outputs') + ' so far. Still working.' : 'Nothing handed off yet. Still working.') : 'Finished at ' + fClock(run.t1 || run.t0));
  return h`<div style="display: flex; flex-direction: column; gap: 14px">
<div style="display: flex; align-items: center; gap: 9px; padding: 10px 12px; border-radius: 12px; background: var(--hs); font-weight: 600"><span class="andon ${run.live ? 'is-on' : ''}"></span><span>${headline}</span></div>
<div style="display: flex; flex-direction: column; gap: 2px">
${items.map(o => h`<div class="outrow"><span class="stepico">${ico(ICON[o.icon] || ICON.file, 14, 2)}</span>
<div style="flex: 1; min-width: 0"><div style="font-weight: 600">${o.title}</div><div style="color: var(--ink-2); text-wrap: pretty">${o.meta}</div>
${o.code ? h`<pre class="code" style="margin-top: 6px; padding: 8px 10px; border-radius: 9px">${o.code}</pre>` : ''}</div></div>`)}
</div>
<div><h3 class="h3" style="margin-bottom: 8px">Final report</h3><pre class="code">${run.report || (run.live ? 'The agent reports when the run ends.' : 'No final message was captured for this run.')}</pre></div>
</div>`;
}

function telemetryTab(D, sd, run, U, now) {
  const td = sd.today || {};
  const today = h`<div><h3 class="h3" style="margin-bottom: 8px">Today at this station</h3>
<div class="tnum" style="display: flex; gap: 26px; flex-wrap: wrap; color: var(--ink-2)">
${[[td.runs || 0, 'runs'], [fTok(td.tok || 0), 'tokens'], [fUsd(td.usd || 0), 'spent'], [(td.cacheRead || 0) + (td.input || 0) ? Math.round(100 * td.cacheRead / (td.cacheRead + td.input)) + '%' : '—', 'from cache'], [td.steps || 0, 'steps']].map(d => h`<div><span style="font-weight: 650; color: var(--ink)">${d[0]}</span> ${d[1]}</div>`)}
</div></div>`;
  if (!D.telemetry) return h`<div style="display: flex; flex-direction: column; gap: 18px">
<div class="hint"><b>Telemetry is off.</b> Tokens, cost and latency appear once Claude Code sends its telemetry here. Add the env block from the plugin’s <span class="mono">templates/settings.mission-control.json</span> to this repo’s <span class="mono">.claude/settings.local.json</span>, then start a new Claude Code session. Steps and GitHub state work without it.</div>
${today}</div>`;
  const unplaced = D.telemetryNote ? h`<div class="hint"><b>Some replies cannot be placed.</b> ${D.telemetryNote}</div>` : '';
  if (!run) return h`<div style="display: flex; flex-direction: column; gap: 18px">${unplaced}<div class="hint"><b>No run seen yet.</b> Tokens and cost for this station show up with its first run.</div>${today}</div>`;
  const acc = run.acc || {}, reps = (run.replies || []).slice(-24), denom = (acc.cacheRead || 0) + (acc.input || 0), pct = denom ? Math.round(100 * acc.cacheRead / denom) : 0;
  const max = Math.max(1, ...reps.map(x => x.input + x.output + x.cacheRead)), H = 92;
  const hov = U.hov !== null && U.hov < reps.length ? U.hov : reps.length - 1;
  const tip = (x, i) => 'Reply ' + (i + 1) + ': ' + fTok(x.input + x.output + x.cacheRead) + ' tokens, ' + fTok(x.input + x.output) + ' new, ' + (x.ms / 1000).toFixed(1) + 's';
  const sec = (run.t1 || now) - run.t0, done = run.steps.filter(s => s.t1 !== null).length;
  const tiles = [['Cost', fUsd(acc.usd || 0), run.live ? 'so far' : 'total'], ['Run time', fDur(sec), run.live ? 'so far' : 'total'], ['Steps', run.total ? done + ' of ' + run.total : String(run.stepCount), 'tool calls'],
    ['Latency', sd.lat === null || sd.lat === undefined ? '—' : sd.lat.toFixed(1) + 's', 'per model reply'], ['New input', fTok(acc.input || 0), 'full price'], ['From cache', fTok(acc.cacheRead || 0), 'a tenth of the price'],
    ['Output', fTok(acc.output || 0), 'written by the model'], ['All tokens', fTok(acc.tok || 0), 'this run']];
  return h`<div style="display: flex; flex-direction: column; gap: 20px">
${unplaced}
<div><h3 class="h3" style="margin-bottom: 9px">${run.live ? 'This run' : 'Last run'}</h3>
<div class="grid4">${tiles.map(k => h`<div class="tile"><div style="color: var(--ink-3); font-size: 11.5px">${k[0]}</div><div style="margin-top: 2px; font-size: 18px; font-weight: 680; letter-spacing: -0.02em">${k[1]}</div><div class="ell" style="color: var(--ink-3); font-size: 11px">${k[2]}</div></div>`)}</div>
</div>
<div>
<div style="display: flex; align-items: baseline; gap: 10px; margin-bottom: 8px"><h3 class="h3">Cache health</h3><span style="flex: 1"></span><span class="tnum" style="font-weight: 650">${denom ? pct + '%' : '—'}</span></div>
<div class="meter" style="height: 8px; border-radius: 4px"><div class="meter-fill" style="width: ${pct}%; border-radius: 4px"></div></div>
<div class="tnum" style="margin-top: 7px; color: var(--ink-3); font-size: 12px; text-wrap: pretty">${denom ? 'Share of this run’s input served from cache. A station that reads 0% has a broken prefix and pays full price for every step.' : 'No model reply has been reported for this run yet.'}</div>
</div>
<div>
<div style="display: flex; align-items: baseline; gap: 12px; flex-wrap: wrap; margin-bottom: 4px">
<h3 class="h3">Tokens per model reply</h3>
<span class="tnum" style="color: var(--ink-3); font-size: 12px">${reps.length ? tip(reps[hov], hov) : 'No reply yet'}</span>
<span style="flex: 1"></span>
<span class="legend"><span class="sw pc"></span>Served from cache</span>
<span class="legend"><span class="sw pn"></span>New input and output</span>
</div>
<div data-act-leave="hov" style="display: flex; align-items: flex-end; height: 104px; max-width: ${Math.max(200, reps.length * 46)}px; padding-top: 8px; border-bottom: 1px solid var(--line-2)">
${reps.map((x, i) => h`<div data-hov="${i}" style="flex: 1 1 0; min-width: 0; height: 100%; display: flex; justify-content: center; align-items: flex-end">
<button class="b0 bar ${i === hov ? 'is-on' : ''}" data-act="hov" data-arg="${i}" aria-label="${tip(x, i)}"><span class="bseg pn" style="height: ${Math.max(3, Math.round((x.input + x.output) / max * H))}px"></span><span class="bseg pc" style="height: ${Math.round(x.cacheRead / max * H)}px"></span></button>
</div>`)}
</div>
</div>
${today}
</div>`;
}

function issuePanel(D, U, now, r) {
  const stopName = s => STATION[s.slot] ? STATION[s.slot].short + (s.round ? (s.slot === 'builder' ? ', fix round ' + s.round : ', round ' + (s.round + 1)) : '') : NAME[s.slot];
  const iconOf = slot => STATION[slot] ? STATION[slot].icon : slot === 'intake' ? ICON.inbox : slot === 'done' ? ICON.merge : ICON.user;
  const dur = s => (s.t1 === null ? now : s.t1) - s.t0;
  const cost = s => STATION[s.slot] && s.tok ? fUsd(s.usd) + ', ' + fTok(s.tok) + ' tokens' : '';
  const past = r.stops.filter(s => s.t1 !== null), cur = r.stops.find(s => s.t1 === null);
  const rows = past.map(s => ({ cls: STATION[s.slot] ? 'h-' + s.slot : 'is-human h-none', icon: iconOf(s.slot), name: stopName(s), state: 'Done', note: s.note, dur: s.auto ? '' : fDur(dur(s)), cost: cost(s), pick: STATION[s.slot] ? s.slot : '' }));
  if (r.phase === 'done') rows.push({ cls: 'h-done', icon: ICON.merge, name: 'Merged', state: r.doneAt ? fClock(r.doneAt) : '', note: 'On main. The line is done with this request.', dur: '', cost: '', pick: '' });
  else if (cur) {
    const st = STATION[cur.slot], run = st && D.stations[cur.slot] ? D.stations[cur.slot].run : null;
    let note = 'Being written up with /adlc-intake.', state = 'Now';
    if (r.phase === 'working') { state = 'Working now'; const open = run && run.live && run.n === r.n ? run.steps.filter(s => s.t1 === null) : []; note = open.length ? open[open.length - 1].label : run && run.live && run.n === r.n && run.steps.length ? run.steps[run.steps.length - 1].label : 'The agent is working.'; }
    else if (r.phase === 'queued') { state = 'Here now'; const busy = D.requests.find(o => o.at === cur.slot && o.phase === 'working'); note = busy ? 'The ' + st.short + ' on this machine is working on #' + busy.n + '.' : 'No run seen on this machine. If this lane runs on GitHub, its work does not show here.'; }
    else if (r.phase === 'waiting') { state = 'Waiting on you'; note = cur.slot === 'gate2' ? 'Read the Action Card, then merge' + (r.pr ? ' PR #' + r.pr : '') + ' in GitHub.' : r.fastRec ? 'The Analyst recommends the fast lane. Apply stage:fast or stage:design in GitHub.' : 'Read the stories, then apply stage:design in GitHub.'; }
    rows.push({ cls: 'is-now ' + (st ? 'h-' + cur.slot : r.phase === 'waiting' ? 'is-human h-you' : 'is-human h-none'), icon: iconOf(cur.slot), name: stopName(cur), state, note, dur: fDur(dur(cur)), cost: cost(cur), pick: st ? cur.slot : '' });
    const path = PATH[r.lane] || PATH.full, at = path.indexOf(r.at);
    (at < 0 ? [] : path.slice(at + 1)).forEach(slot => rows.push({ cls: 'is-next ' + (STATION[slot] ? 'h-' + slot : 'is-human h-none'), icon: iconOf(slot), name: STATION[slot] ? STATION[slot].short : NAME[slot], state: 'Up next', note: NEXTNOTE[slot], dur: '', cost: '', pick: '' }));
  }
  const sum = (f, k) => r.stops.filter(f).reduce((a, s) => a + (k === 'sec' ? dur(s) : s[k] || 0), 0);
  const isAgent = s => !!STATION[s.slot], isGate = s => s.slot === 'gate1' || s.slot === 'gate2';
  const stNow = STATION[r.at];
  const status = r.phase === 'working' ? 'With the ' + stNow.short : r.phase === 'queued' ? 'At the ' + stNow.short : r.phase === 'waiting' ? 'Waiting on you at ' + NAME[r.at] : r.phase === 'done' ? 'Merged' : 'In intake';
  const chips = [r.lane === 'fast' ? 'Fast lane' : 'Full lane', r.autopilot ? 'Autopilot' : '', r.pr ? 'PR #' + r.pr : '', r.adr ? 'ADR ' + pad(r.adr, 4) : '', r.alert].filter(Boolean);
  const stats = [[fMin((r.doneAt || now) - r.born), 'Since it was filed'], [fMin(sum(isAgent, 'sec')), 'Agent time'], [fMin(sum(isGate, 'sec')), 'Waiting on you'],
    [D.telemetry ? fTok(sum(isAgent, 'tok')) : '—', 'Tokens'], [D.telemetry ? fUsd(sum(isAgent, 'usd')) : '—', 'Cost']];
  const bar = r.stops.filter(s => s.slot !== 'intake' && s.slot !== 'done' && dur(s) > 0);
  const epic = (D.epics.find(e => e.key === r.epic) || {}).name || '';
  return h`<div class="${hueOf(r)}" style="flex: 1; min-height: 0; display: flex; flex-direction: column">
<div style="flex: none; padding: 16px 18px 14px; display: flex; flex-direction: column; gap: 11px; border-bottom: 1px solid var(--line)">
<div style="display: flex; align-items: flex-start; gap: 12px">
<div style="flex: 1; min-width: 0">
<div class="tnum" style="color: var(--ink-3); font-size: 12px">Issue #${r.n}${epic ? ' in ' + epic : ''}</div>
<h2 style="margin: 2px 0 0; font-size: 18px; font-weight: 680; letter-spacing: -0.02em; text-wrap: balance">${r.title}</h2>
</div>
${r.url ? h`<a class="pillbtn" href="${r.url}" target="_blank" rel="noopener" style="flex: none; height: 30px; font-size: 12.5px; text-decoration: none; color: inherit">Open in GitHub${ico(ICON.ext, 13, 2)}</a>` : h`<button class="b0 pillbtn" data-act="open" data-arg="${r.n}" style="flex: none; height: 30px; font-size: 12.5px">Open in GitHub${ico(ICON.ext, 13, 2)}</button>`}
</div>
<div style="display: flex; gap: 6px; flex-wrap: wrap; align-items: center">
<span class="status ${r.phase === 'working' || r.phase === 'waiting' ? 'is-on' : ''}"><span class="andon ${r.phase === 'working' ? 'is-on' : r.phase === 'waiting' ? 'is-warn' : ''}"></span>${status}</span>
${chips.map(c => h`<span class="chip">${c}</span>`)}
</div>
<div class="tnum" style="display: flex; gap: 28px; flex-wrap: wrap">${stats.map(k => h`<div><div style="font-size: 16px; font-weight: 680; letter-spacing: -0.02em">${k[0]}</div><div style="color: var(--ink-3); font-size: 11.5px">${k[1]}</div></div>`)}</div>
</div>
<div class="scroll" data-scroll="right" style="flex: 1; min-height: 0; padding: 14px 18px 18px; display: flex; flex-direction: column; gap: 18px">
<div>
<h3 class="h3" style="margin-bottom: 8px">Where the time went</h3>
<div style="display: flex; gap: 2px; height: 14px">${bar.map(s => h`<span class="${STATION[s.slot] ? 'seg-a h-' + s.slot : 'seg-w'}" title="${stopName(s)}, ${fDur(dur(s))}" style="display: block; flex: ${Math.max(1, Math.round(dur(s)))} 1 0; min-width: 3px; border-radius: 3px"></span>`)}</div>
<div style="margin-top: 7px; color: var(--ink-3); font-size: 12px">Color is agent time, in the order of the journey below. Gray is time spent waiting on you.</div>
</div>
<div>
<h3 class="h3" style="margin-bottom: 6px">Journey</h3>
<ol style="list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column">
${rows.map(s => h`<li class="stop ${s.cls}"><span class="stop-mark">${ico(s.icon, 13, 2.1)}</span>
<div style="flex: 1; min-width: 0">
<div style="display: flex; align-items: baseline; gap: 8px; flex-wrap: wrap">${s.pick ? h`<button class="b0 issue-link" data-act="station" data-arg="${s.pick}" style="font-weight: 600">${s.name}</button>` : h`<span style="font-weight: 600">${s.name}</span>`}<span style="color: var(--ink-3); font-size: 12px">${s.state}</span></div>
<div style="color: var(--ink-2); text-wrap: pretty">${s.note}</div>
</div>
<div class="tnum" style="flex: none; text-align: right; font-size: 12px; line-height: 1.5; color: var(--ink-2)"><div>${s.dur}</div><div style="color: var(--ink-3)">${s.cost}</div></div>
</li>`)}
</ol>
</div>
${r.tasks ? h`<div>
<h3 class="h3" style="margin-bottom: 6px">Tasks from the Architect</h3>
${r.tasks.map(t => h`<div style="display: flex; align-items: flex-start; gap: 10px; padding: 7px 8px"><span class="taskbox ${t.state === 'done' ? 'is-done' : t.state === 'now' ? 'is-now' : ''}">${ico(ICON.check, 12, 3)}</span>
<div style="flex: 1; min-width: 0"><div style="font-weight: 500">${t.title}</div><div class="mono ell" style="color: var(--ink-3); font-size: 11.5px">${t.scope}</div></div>
<span style="flex: none; color: var(--ink-3); font-size: 12px">${t.state === 'done' ? 'Done' : t.state === 'now' ? 'Building' : 'Waiting'}</span></div>`)}
</div>` : ''}
</div>
</div>`;
}

function page(D, U, now) {
  const waiting = D.requests.filter(r => r.phase === 'waiting').sort((a, b) => a.since - b.since);
  const picked = U.sel.type === 'issue' ? D.requests.find(r => r.n === U.sel.n) : null;
  const notice = A.lost ? 'Lost the connection to Mission Control. Is it still running? This page reconnects on its own.'
    : A.trouble ? 'Mission Control could not build this view: ' + A.trouble + '. The page shows what it had; the terminal it runs in has the details.'
    : D.mode !== 'demo' && !D.repo ? 'No GitHub repo was found. Start Mission Control inside a repo, or pass --repo owner/name.'
    : D.mode !== 'demo' && !D.github.ok && D.github.msg ? 'GitHub could not be read: ' + D.github.msg + '. Showing what was read last.' : '';
  return h`<div class="mc ${U.playing ? '' : 'is-paused'}" data-theme="${U.dark ? 'dark' : 'light'}" data-pal="${U.pal}" style="height: 100vh; min-height: 720px; display: flex; flex-direction: column; gap: 12px; padding: 0 20px 16px; background: var(--page); color: var(--ink); font-size: 13px; line-height: 1.4; overflow: hidden">
${U.repoMenu ? h`<button class="b0" aria-label="Close the repository menu" data-act="closeMenus" style="position: absolute; inset: 0; z-index: 30; cursor: default"></button>` : ''}
${topBar(D, U, waiting)}
${notice ? h`<div class="banner" role="status" style="flex: none">${ico(ICON.alert, 16, 2)}<span>${notice}</span></div>` : ''}
${line(D, U, now)}
<div class="mc-panels" style="flex: 1; min-height: 0; display: flex; gap: 14px">
${leftPanel(D, U, now)}
<section class="mc-right panel" aria-label="Inspector" style="flex: 1; min-width: 0; display: flex; flex-direction: column">
${picked ? issuePanel(D, U, now, picked) : stationPanel(D, U.sel.type === 'station' ? U : Object.assign({}, U, { sel: { type: 'station', id: 'builder' } }), now)}
</section>
</div>
${U.toast ? h`<div class="toast" role="status">${U.toast}</div>` : ''}
</div>`;
}

// ------------------------------------------------------------------------------------ render + actions
const root = document.getElementById('app');
function render() {
  if (!A.data) { if (A.trouble) root.textContent = 'Mission Control could not build this view: ' + A.trouble + '. The terminal it runs in has the details.'; return; }
  const U = A.ui;
  U.dark = U.theme ? U.theme === 'dark' : U.pal === 'cool';
  const tpl = document.createElement('template');
  tpl.innerHTML = page(A.data, U, clock()).__raw;
  const next = tpl.content.firstElementChild;
  if (root.firstElementChild) morph(root.firstElementChild, next); else { root.textContent = ''; root.appendChild(next); }
}
const scrollTop = () => { const el = root.querySelector('[data-scroll="right"]'); if (el) el.scrollTop = 0; };
let toastTimer = 0;
function toast(text) { clearTimeout(toastTimer); A.ui.toast = text; render(); toastTimer = setTimeout(() => { A.ui.toast = null; render(); }, 2400); }

const actions = {
  station: id => { A.ui.sel = { type: 'station', id }; A.ui.hov = null; A.ui.ctx = 'agent'; A.ui.repoMenu = false; render(); scrollTop(); },
  issue: n => { if (n === '') return; const num = Number(n); if (!A.data.requests.some(r => r.n === num)) return toast('#' + num + ' is no longer on the line'); A.ui.sel = { type: 'issue', n: num }; A.ui.repoMenu = false; render(); scrollTop(); },
  gate: slot => { const w = A.data.requests.filter(r => r.at === slot && r.phase === 'waiting').sort((a, b) => a.since - b.since); if (w.length) actions.issue(w[0].n); else toast('Nothing is waiting at ' + NAME[slot]); },
  waiting: () => { const w = A.data.requests.filter(r => r.phase === 'waiting').sort((a, b) => a.since - b.since); if (w.length) actions.issue(w[0].n); else toast('Nothing is waiting on you'); },
  tab: id => { A.ui.tab = id; A.ui.hov = null; render(); scrollTop(); },
  left: id => { A.ui.left = id; render(); },
  ctx: id => { A.ui.ctx = A.ui.ctx === id ? null : id; render(); },
  lane: id => { A.ui.lane = id; render(); },
  epic: key => { if (!A.ui.closed.delete(key)) A.ui.closed.add(key); render(); },
  hov: i => { A.ui.hov = Number(i); render(); },
  theme: () => { A.ui.theme = A.ui.dark ? 'light' : 'dark'; save(); render(); },
  play: () => { A.ui.playing = !A.ui.playing; A.frozenAt = A.ui.playing ? null : clock(); if (A.ui.playing && A.data.mode !== 'demo') connect(); render(); },
  repoMenu: () => { A.ui.repoMenu = !A.ui.repoMenu; render(); },
  closeMenus: () => { A.ui.repoMenu = false; render(); },
  repo: name => { A.ui.repoMenu = false; A.ui.repo = name; A.ui.sel = { type: 'station', id: 'builder' }; A.pool.length = 0; A.seen.clear(); A.arr.clear(); save(); if (A.demo) { A.demo.pick(name); A.data = A.demo.state(); render(); } else connect(); },
  open: n => toast('In demo mode there is no real issue #' + n + ' to open')
};
root.addEventListener('click', ev => { const el = ev.target.closest('[data-act]'); if (el && root.contains(el) && actions[el.dataset.act]) actions[el.dataset.act](el.dataset.arg, el); });
root.addEventListener('mouseover', ev => { const el = ev.target.closest('[data-hov]'); if (el && A.ui.hov !== Number(el.dataset.hov)) actions.hov(el.dataset.hov); });
root.addEventListener('mouseout', ev => { const el = ev.target.closest('[data-act-leave]'); if (el && !el.contains(ev.relatedTarget) && A.ui.hov !== null) { A.ui.hov = null; render(); } });

// ------------------------------------------------------------------------------------ data
function connect() {
  if (A.source) A.source.close();
  const src = new EventSource('/api/events' + (A.ui.repo ? '?repo=' + encodeURIComponent(A.ui.repo) : ''));
  A.source = src;
  src.addEventListener('state', ev => { if (!A.ui.playing) return; A.data = JSON.parse(ev.data); A.at = performance.now(); A.lost = false; A.trouble = ''; render(); });
  src.addEventListener('trouble', ev => { try { A.trouble = JSON.parse(ev.data).error || 'an error'; } catch (e) { A.trouble = 'an error'; } render(); });
  src.onerror = () => { if (!A.lost) { A.lost = true; render(); } };
}

async function boot() {
  try { A.meta = await (await fetch('/api/meta')).json(); } catch (e) { A.meta = { stations: [], demo: true }; }
  A.meta.stations.forEach(a => { A.agents[a.station] = a; });
  if (A.meta.demo || params.has('demo')) {
    A.demo = createDemo(A.meta);
    const speed = Number(params.get('speed')) || 1;
    A.data = A.demo.state();
    render();
    setInterval(() => { if (!A.ui.playing) return; A.demo.tick(speed); A.data = A.demo.state(); render(); }, 1000);
  } else {
    connect();
    setInterval(() => { if (A.ui.playing && A.data) render(); }, 1000);
  }
}
boot();
