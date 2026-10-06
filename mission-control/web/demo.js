// Demo mode: a simulated pipeline, so the page can be shown and tested without GitHub or a running agent.
// It produces the same state document the server builds from real data (see mc/state.py).
// Everything here is made up: the repos, the requests, the timings and the token counts.

const CLAUDE_TOK = 700;
const ST = [
  { id: 'analyst', name: 'Product Analyst', short: 'Analyst', model: 'opus', inRate: 5, outRate: 25, lat: 3.2, sysTok: 9400, agentTok: 900, grow: 2400, newTok: 1800, outTok: 700, stepSec: 78, fp: '8f2c1e',
    file: 'agents/product-analyst.md', trigger: 'stage:intake', start: 'Starts on stage:intake',
    role: 'Turns a request into user stories with pass or fail acceptance checks, and recommends a lane. You choose the lane at Gate 1.',
    boundary: 'Read-only on the repo. It can only comment on issues and move one to gate:stories.',
    skills: [['adlc:charter', 2600], ['project-conventions', 1800], ['adlc:edd-spec', 2100], ['triage', 1300], ['verify', 1100]],
    steps: [['read', 'Reading issue {n} and the linked brief'], ['search', 'Searching the repo for related code'], ['think', 'Checking the request is complete'], ['think', 'Sizing the change for triage'], ['write', 'Writing stories and acceptance checks'], ['gh', 'Posting the story set on {n}'], ['gh', 'Moving {n} to gate:stories']] },
  { id: 'architect', name: 'Architect', short: 'Architect', model: 'opus', inRate: 5, outRate: 25, lat: 3.4, sysTok: 10800, agentTok: 800, grow: 2600, newTok: 2100, outTok: 900, stepSec: 84, fp: '3ab90d',
    file: 'agents/architect.md', trigger: 'stage:design', start: 'Starts on stage:design',
    role: 'Writes the design decision and splits the work into tasks, each listing the exact files allowed. Later it checks the pull request matches that design.',
    boundary: 'Writes under docs/ only. It never touches application code and never merges.',
    skills: [['adlc:charter', 2600], ['project-conventions', 1800], ['release-ops', 1500], ['verify', 1100]],
    steps: [['read', 'Reading the approved stories for {n}'], ['search', 'Mapping the files this change touches'], ['gh', 'Checking open builds for file conflicts'], ['write', 'Writing {adr}'], ['write', 'Splitting the work into tasks with allowed files'], ['gh', 'Posting the task breakdown on {n}'], ['gh', 'Moving {n} to stage:build']] },
  { id: 'builder', name: 'Builder', short: 'Builder', model: 'fable', inRate: 3, outRate: 15, lat: 1.8, sysTok: 11600, agentTok: 700, grow: 2800, newTok: 2400, outTok: 1100, stepSec: 82, fp: 'c41f77',
    file: 'agents/builder.md', trigger: 'stage:build', start: 'Starts on stage:build',
    role: 'Writes the code and a test for every acceptance check, on its own branch, then opens a pull request. It never merges.',
    boundary: 'Works on its own feature branch, inside the files the task allows. A scope check stops any commit outside them.',
    skills: [['adlc:charter', 2600], ['project-conventions', 1800], ['adlc:security-gate', 2200], ['verify', 1100], ['efficient-runs', 800]],
    steps: [['read', 'Reading the ADR and task breakdown'], ['bash', 'Creating branch feat/{slug}'], ['edit', 'Implementing the tasks inside their allowed files'], ['edit', 'Writing a test for each acceptance check'], ['bash', 'Running the test suite'], ['edit', 'Fixing a failing assertion'], ['bash', 'Running type-check and build'], ['gh', 'Opening the pull request']],
    fixSteps: [['gh', 'Reading the review findings on {pr}'], ['edit', 'Fixing the High finding inside the allowed files'], ['bash', 'Re-running the test suite'], ['bash', 'Pushing an adlc-fix commit to {pr}']] },
  { id: 'reviewer', name: 'Adversarial Reviewer', short: 'Reviewer', model: 'fable', inRate: 3, outRate: 15, lat: 1.7, sysTok: 9900, agentTok: 1000, grow: 2300, newTok: 1900, outTok: 800, stepSec: 70, fp: '5e0a92',
    file: 'agents/adversarial-reviewer.md', trigger: 'pull request opened', start: 'Starts on a new pull request',
    role: 'Starts with fresh context, sees only the change, and tries to break it. The Architect then checks the design was followed.',
    boundary: 'Read-only. It can only comment on the pull request. It cannot edit code, change labels or merge.',
    skills: [['adlc:code-review', 1900], ['project-conventions', 1800], ['adlc:security-gate', 2200]],
    steps: [['gh', 'Reading the diff of {pr}'], ['read', 'Reading the ADR, tasks and acceptance checks'], ['think', 'Hunting edge cases the happy path hides'], ['search', 'Checking every unfamiliar symbol exists'], ['think', 'Walking the security attack classes'], ['think', 'Testing the strongest case that it is wrong'], ['gh', 'Posting findings and the verdict']] },
  { id: 'qa', name: 'QA & Release-Ops', short: 'QA', model: 'opus', inRate: 5, outRate: 25, lat: 3.3, sysTok: 11600, agentTok: 900, grow: 3000, newTok: 2600, outTok: 900, stepSec: 88, fp: 'd7163b',
    file: 'agents/qa-release-ops.md', trigger: 'stage:qa', start: 'Starts on stage:qa',
    role: 'Runs the full test suite, fills test gaps, does a security pass, and drafts the merge proposal for you.',
    boundary: 'Writes in the test folders only. It never merges, deploys or runs a migration.',
    skills: [['adlc:charter', 2600], ['project-conventions', 1800], ['adlc:edd-spec', 2100], ['adlc:security-gate', 2200], ['adlc:code-review', 1900], ['release-ops', 1500], ['verify', 1100], ['efficient-runs', 800]],
    steps: [['bash', 'Checking out the branch of {pr}'], ['read', 'Mapping acceptance checks to tests'], ['edit', 'Writing a missing test'], ['bash', 'Running the full test suite'], ['think', 'Trying tenant escapes and auth bypass'], ['write', 'Drafting the Proposed Action Card'], ['gh', 'Moving {n} to gate:deploy']] }
];
const AG = {};
ST.forEach((s, i) => { s.i = i; s.prefix = s.sysTok + s.agentTok + CLAUDE_TOK + s.skills.reduce((a, x) => a + x[1], 0); AG[s.id] = s; });

// The route each lane takes down the line. The simulator moves requests along it; app.js holds the same two lists for drawing.
const PATH = { full: ['intake', 'analyst', 'gate1', 'architect', 'builder', 'reviewer', 'qa', 'gate2', 'done'], fast: ['intake', 'analyst', 'gate1', 'builder', 'reviewer', 'gate2', 'done'] };
const TICK = 15;

const REPOS = {
  storefront: { name: 'sample/storefront', off: 0, epics: { sec: 'Account security', pay: 'Checkout', keep: 'Housekeeping' }, areas: { sec: 'auth', pay: 'checkout', keep: 'site' },
    pool: [['Password reset link', 'sec', 'full'], ['Rate-limit sign-in attempts', 'sec', 'full'], ['Fix typo on the pricing page', 'keep', 'fast'], ['Guest checkout', 'pay', 'full', { fixes: 2 }], ['Apply promo codes at checkout', 'pay', 'full', { autopilot: true }], ['Order confirmation email', 'pay', 'full'], ['Export orders as CSV', 'pay', 'full'], ['Update the footer year', 'keep', 'fast'], ['Session timeout setting', 'sec', 'full'], ['Saved delivery addresses', 'pay', 'full', { fixes: 1 }], ['Raise log level for payment retries', 'keep', 'fast'], ['Sign in with an email code', 'sec', 'full', { autopilot: true }], ['Show tax before payment', 'pay', 'full'], ['Rename Basket to Cart', 'keep', 'fast']] },
  billing: { name: 'sample/billing-api', off: -61, epics: { inv: 'Invoices', sub: 'Subscriptions', ops: 'Housekeeping' }, areas: { inv: 'invoices', sub: 'subscriptions', ops: 'ops' },
    pool: [['Prorate mid-cycle plan changes', 'sub', 'full'], ['Retry failed card charges', 'sub', 'full'], ['Correct the VAT label on invoices', 'ops', 'fast'], ['Invoice PDF download', 'inv', 'full', { fixes: 2 }], ['Credit notes', 'inv', 'full', { autopilot: true }], ['Webhook for paid invoices', 'inv', 'full'], ['Pause a subscription', 'sub', 'full'], ['Quiet the dunning email logs', 'ops', 'fast'], ['Annual billing option', 'sub', 'full'], ['Tax ID on invoices', 'inv', 'full', { fixes: 1 }], ['Fix currency rounding in the footer', 'ops', 'fast'], ['Usage-based line items', 'inv', 'full']] },
  docs: { name: 'sample/docs-site', off: 112, epics: { guide: 'Guides', ref: 'Reference', site: 'Site' }, areas: { guide: 'guides', ref: 'reference', site: 'site' },
    pool: [['Search across guides', 'site', 'full'], ['Versioned API reference', 'ref', 'full'], ['Fix broken link in the quickstart', 'guide', 'fast'], ['Copy button on code samples', 'site', 'full', { fixes: 2 }], ['Changelog page', 'site', 'full', { autopilot: true }], ['Dark theme for the docs', 'site', 'full'], ['Webhook reference', 'ref', 'full'], ['Correct the install command', 'guide', 'fast'], ['Feedback widget on pages', 'site', 'full'], ['Migration guide for v2', 'guide', 'full', { fixes: 1 }], ['Update the license year', 'site', 'fast'], ['Error code reference', 'ref', 'full']] }
};

const pad = (v, n) => String(v).padStart(n, '0');
function rnd(a, b, c) { let h = (Math.imul(a | 0, 374761393) + Math.imul(b | 0, 668265263) + Math.imul(c | 0, 2246822519)) | 0; h = Math.imul(h ^ (h >>> 13), 1274126177); h ^= h >>> 16; h = Math.imul(h, 2654435761); h ^= h >>> 15; return (h >>> 0) / 4294967296; }
const fTok = v => v >= 1e6 ? (v / 1e6).toFixed(2) + 'M' : v >= 1e4 ? Math.round(v / 1e3) + 'k' : v >= 1e3 ? (v / 1e3).toFixed(1) + 'k' : String(Math.round(v));
const fClock = s => pad(Math.floor(s / 3600) % 24, 2) + ':' + pad(Math.floor(s / 60) % 60, 2);
const slugify = t => { const w = t.toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim().split(' '); let out = ''; for (const x of w) { if (out && (out + '-' + x).length > 24) break; out = out ? out + '-' + x : x; } return out; };
const fill = (label, is) => label.replace(/\{(\w+)\}/g, (m, k) => k === 'n' ? '#' + is.n : k === 'slug' ? is.n + '-' + is.slug : k === 'pr' ? 'PR #' + (is.pr || '') : k === 'adr' ? 'ADR ' + pad(is.adr || 0, 4) : m);
const sid = (n, i, round) => pad(Math.floor(rnd(n, i, round + 40) * 0xffffff).toString(16), 6) + pad(Math.floor(rnd(n + 3, i, round + 41) * 0xffff).toString(16), 4);

const planMemo = new Map();
function plan(st, n, round) {
  const key = st.id + ':' + n + ':' + round;
  let p = planMemo.get(key);
  if (p) return p;
  const labels = round > 0 && st.fixSteps ? st.fixSteps : st.steps;
  let conv = 0, cum = 0;
  const steps = [];
  for (let i = 0; i < labels.length; i++) {
    const r1 = rnd(n, st.i * 31 + round * 7 + 1, i), r2 = rnd(n + 7, st.i * 17 + round * 3 + 2, i), r3 = rnd(n + 13, st.i * 5 + round + 3, i);
    const sec = Math.round(st.stepSec * (0.55 + r1 * 0.9));
    const input = Math.round(i === 0 ? 1800 + r2 * 3200 : 300 + r2 * st.newTok);
    const output = Math.round(140 + r3 * st.outTok);
    const cacheRead = st.prefix + conv;
    const usd = ((cacheRead * 0.1 + input * 1.25) * st.inRate + output * st.outRate) / 1e6;
    cum += sec;
    steps.push({ i, kind: labels[i][0], label: labels[i][1], sec, input, output, cacheRead, tok: cacheRead + input + output, usd, cum });
    conv += input + output;
  }
  p = { steps, total: cum, max: Math.max.apply(null, steps.map(s => s.tok)) };
  planMemo.set(key, p);
  return p;
}
const blankStop = (slot, round, t0) => ({ slot, round, t0, sec: 0, tok: 0, usd: 0, input: 0, cacheRead: 0, output: 0, steps: 0, note: '', auto: false });
function addStep(acc, s) { acc.tok += s.tok; acc.usd += s.usd; acc.input += s.input; acc.cacheRead += s.cacheRead; acc.output += s.output; acc.steps += 1; }
function say(sim, who, n, text) { sim.feed.unshift({ t: sim.clock, who, n, text }); if (sim.feed.length > 40) sim.feed.pop(); }

function makeIssue(sim, def, n) {
  const x = def[3] || {}, fast = def[2] === 'fast';
  const stories = fast ? 1 : 2 + Math.floor(rnd(n, 2, 2) * 3);
  const acs = fast ? 1 : stories * 2 + Math.floor(rnd(n, 4, 4) * 3);
  return { n, title: def[0], slug: slugify(def[0]), epic: def[1], lane: def[2], autopilot: !!x.autopilot, fixes: x.fixes || 0, round: 0, pr: null, adr: null,
    stories, acs, files: fast ? 1 + Math.floor(rnd(n, 3, 3) * 2) : 3 + Math.floor(rnd(n, 3, 3) * 4), lines: 4 + Math.floor(rnd(n, 8, 8) * 22), tests: acs * 3 + Math.floor(rnd(n, 6, 6) * 6), suite: 184 + Math.floor(rnd(n, 7, 7) * 80),
    at: 'intake', phase: 'filing', el: 0, need: 60 + Math.round(rnd(n, 1, 1) * 45), stepsDone: 0, qAt: sim.seq++, arr: sim.tick, hist: [], cur: blankStop('intake', 0, sim.clock), born: sim.clock, doneAt: 0 };
}
function nextSlot(is) { if (is.at === 'reviewer' && is.round < is.fixes) return 'builder'; const p = PATH[is.lane]; return p[p.indexOf(is.at) + 1]; }
function noteFor(sim, is) {
  const n = '#' + is.n, fast = is.lane === 'fast';
  switch (is.at) {
    case 'intake': return { note: 'Filed with the stage:intake label', who: 'you', text: 'filed ' + n + ' with stage:intake' };
    case 'analyst': return fast ? { note: 'Change brief with one acceptance check. ADLC-TRIAGE: FAST', who: 'analyst', text: 'posted a change brief on ' + n + ' and recommends the fast lane' } : { note: is.stories + ' stories and ' + is.acs + ' acceptance checks. ADLC-TRIAGE: FULL', who: 'analyst', text: 'posted ' + is.stories + ' stories and ' + is.acs + ' acceptance checks on ' + n };
    case 'gate1': return is.cur.auto ? { note: 'Autopilot approved the plan', who: 'auto', text: 'approved the plan for ' + n + '. Label stage:design' } : fast ? { note: 'You approved the fast lane', who: 'you', text: 'approved the fast lane for ' + n + '. Label stage:fast' } : { note: 'You approved the plan', who: 'you', text: 'approved the plan for ' + n + '. Label stage:design' };
    case 'architect': return { note: 'ADR ' + pad(is.adr, 4) + ' and 3 tasks, each with its allowed files', who: 'architect', text: 'wrote ADR ' + pad(is.adr, 4) + ' and split ' + n + ' into 3 tasks. Label stage:build' };
    case 'builder':
      if (!is.pr) { is.pr = sim.nextPR; sim.nextPR += 1 + Math.floor(rnd(is.n, 11, 11) * 3); }
      return is.round ? { note: 'Pushed fix round ' + is.round + ' to PR #' + is.pr, who: 'builder', text: 'pushed fix round ' + is.round + ' to PR #' + is.pr } : { note: 'Opened PR #' + is.pr + ' with ' + is.files + ' files and ' + is.tests + ' tests', who: 'builder', text: 'opened PR #' + is.pr + ' for ' + n };
    case 'reviewer':
      if (is.round < is.fixes) return { note: 'ADLC-ADV: CHANGES, 1 High finding', who: 'reviewer', text: 'requested changes on PR #' + is.pr + '. Fix round ' + (is.round + 1) + ' of 3' };
      return fast ? { note: 'ADLC-ADV: PASS. The size cap held', who: 'reviewer', text: 'passed PR #' + is.pr + '. Label gate:deploy' } : { note: 'ADLC-ADV: PASS and ADLC-ARCH: PASS', who: 'reviewer', text: 'passed PR #' + is.pr + '. Label stage:qa' };
    case 'qa': return { note: is.suite + ' tests passed, ' + is.acs + ' of ' + is.acs + ' checks covered. Action card posted', who: 'qa', text: 'posted the Proposed Action Card for ' + n + '. Label gate:deploy' };
    default: return { note: 'You merged PR #' + is.pr, who: 'you', text: 'merged PR #' + is.pr + ' for ' + n };
  }
}
function closeStop(sim, is, quiet) {
  const info = noteFor(sim, is);
  is.cur.note = info.note;
  if (!quiet) say(sim, info.who, is.n, info.text);
  if (AG[is.at] && sim.last[is.at] && sim.last[is.at].is === is) sim.last[is.at].t1 = sim.clock;
  is.hist.push(is.cur);
  const nx = nextSlot(is);
  if (is.at === 'reviewer' && nx === 'builder') is.round++;
  is.at = nx; is.el = 0; is.stepsDone = 0; is.qAt = sim.seq++; is.arr = sim.tick;
  is.cur = blankStop(nx, is.round, sim.clock);
  if (nx === 'architect' && !is.adr) is.adr = sim.nextAdr++;
}
function settle(sim, is, quiet) {
  const slot = is.at;
  if (AG[slot]) {
    const busy = sim.pool.some(o => o && o !== is && o.at === slot && o.phase === 'working');
    is.phase = busy ? 'queued' : 'working';
    if (!busy) sim.last[slot] = { is, round: is.round, t1: 0 };
  } else if (slot === 'done') {
    is.phase = 'done'; is.doneAt = sim.clock; sim.merged++;
  } else {
    if (slot === 'gate1' && is.autopilot && is.lane === 'full') { is.cur.auto = true; closeStop(sim, is, quiet); return settle(sim, is, quiet); }
    is.phase = 'waiting';
    is.need = 240 + Math.round(rnd(is.n, 9, slot.length) * 300);
    if (slot === 'gate2') { sim.lead.push(is.hist.reduce((a, h) => a + h.sec, 0)); if (sim.lead.length > 7) sim.lead.shift(); }
    if (!quiet) say(sim, slot, is.n, slot === 'gate1' ? '#' + is.n + ' is waiting for your plan approval' : '#' + is.n + ' is ready for you to merge');
  }
}
function seed(key) {
  const repo = REPOS[key];
  const sim = { key, clock: 14 * 3600 + 120, tick: 0, seq: 1, pool: new Array(10).fill(null), gone: {}, feed: [], merged: 3, nextPR: 141 + repo.off, nextAdr: 6, nextN: 154 + repo.off, backlog: 8, defs: repo.pool, today: {}, last: {}, lat: {}, lead: [3120, 2760, 3480] };
  ST.forEach((st, i) => {
    const ref = plan(st, 90 + i, 0), runs = [6, 5, 6, 7, 4][i];
    const sum = k => ref.steps.reduce((a, s) => a + s[k], 0) * runs;
    sim.today[st.id] = { tok: sum('tok'), usd: sum('usd'), input: sum('input'), cacheRead: sum('cacheRead'), output: sum('output'), sec: ref.total * runs, steps: ref.steps.length * runs, runs };
    sim.lat[st.id] = st.lat;
  });
  const init = [[7, 'done', 128], [5, 'gate2', 133], [4, 'qa', 135], [3, 'reviewer', 139], [0, 'builder', 142], [1, 'architect', 147], [2, 'gate1', 151], [6, 'analyst', 153]];
  const frac = { qa: 0.42, reviewer: 0.56, builder: 0.47, architect: 0.3, analyst: 0.52 };
  init.forEach((row, idx) => {
    const slot = row[1], is = makeIssue(sim, repo.pool[row[0]], row[2] + repo.off);
    sim.pool[idx] = is;
    const round = slot === 'reviewer' ? 1 : 0;
    let guard = 0;
    while (!(is.at === slot && is.round === round) && guard++ < 40) {
      const st = AG[is.at];
      if (st) { const p = plan(st, is.n, is.round); p.steps.forEach(s => addStep(is.cur, s)); is.cur.sec = p.total; }
      else if (is.at === 'intake') is.cur.sec = is.need;
      else if (is.at === 'gate1' && is.autopilot && is.lane === 'full') { is.cur.auto = true; is.cur.sec = 0; }
      else is.cur.sec = 300 + Math.round(rnd(is.n, 5, is.at.length) * 1300);
      closeStop(sim, is, true);
    }
    if (AG[slot]) {
      const p = plan(AG[slot], is.n, is.round);
      is.phase = 'working'; is.el = Math.round(p.total * frac[slot]);
      while (is.stepsDone < p.steps.length && p.steps[is.stepsDone].cum <= is.el) addStep(is.cur, p.steps[is.stepsDone++]);
      is.cur.sec = is.el; is.cur.t0 = sim.clock - is.el;
      sim.last[slot] = { is, round: is.round, t1: 0 };
    } else if (slot === 'done') { is.phase = 'done'; is.doneAt = sim.clock - 75; }
    else { is.phase = 'waiting'; is.el = slot === 'gate1' ? 840 : 2280; is.need = is.el + (slot === 'gate1' ? 200 : 350); is.cur.sec = is.el; is.cur.t0 = sim.clock - is.el; }
    is.born = (is.phase === 'done' ? is.doneAt : sim.clock) - is.hist.reduce((a, h) => a + h.sec, 0) - is.el;
    is.arr = -10;
  });
  const at = s => sim.pool.find(o => o && o.at === s);
  const c = sim.clock;
  sim.feed = [
    { t: c - 60, who: 'builder', n: at('builder').n, text: 'started building #' + at('builder').n },
    { t: c - 300, who: 'reviewer', n: at('reviewer').n, text: 'requested changes on PR #' + at('reviewer').pr + '. Fix round 1 of 3' },
    { t: c - 840, who: 'gate1', n: at('gate1').n, text: '#' + at('gate1').n + ' is waiting for your lane approval' },
    { t: c - 900, who: 'analyst', n: at('gate1').n, text: 'posted a change brief on #' + at('gate1').n + ' and recommends the fast lane' },
    { t: c - 1380, who: 'auto', n: at('qa').n, text: 'approved the plan for #' + at('qa').n + '. Label stage:design' },
    { t: c - 2280, who: 'gate2', n: at('gate2').n, text: '#' + at('gate2').n + ' is ready for you to merge' },
    { t: c - 2340, who: 'qa', n: at('gate2').n, text: 'posted the Proposed Action Card for #' + at('gate2').n + '. Label gate:deploy' }
  ];
  return sim;
}
function tick(sim, speed) {
  const dt = TICK * speed;
  sim.clock += dt; sim.tick++;
  const liveN = sim.pool.filter(o => o && o.phase !== 'done').length;
  if (liveN < 7 && sim.tick % 6 === 2) {
    const idx = sim.pool.findIndex(o => !o);
    if (idx >= 0) { const is = makeIssue(sim, sim.defs[sim.backlog++ % sim.defs.length], sim.nextN++); sim.pool[idx] = is; say(sim, 'you', is.n, 'started request #' + is.n + ' with /adlc-intake'); }
  }
  sim.pool.forEach(is => {
    if (!is) return;
    if (is.phase === 'filing' || is.phase === 'waiting') {
      is.el += dt; is.cur.sec = is.el;
      if (is.el >= is.need) { closeStop(sim, is, false); settle(sim, is, false); }
    } else if (is.phase === 'working') {
      const st = AG[is.at], p = plan(st, is.n, is.round), t = sim.today[st.id];
      is.el += dt;
      while (is.stepsDone < p.steps.length && p.steps[is.stepsDone].cum <= is.el) { const s = p.steps[is.stepsDone++]; addStep(is.cur, s); addStep(t, s); t.sec += s.sec; }
      is.cur.sec = Math.min(is.el, p.total);
      sim.lat[st.id] = sim.lat[st.id] * 0.8 + st.lat * (0.85 + 0.3 * rnd(sim.tick, st.i, 3)) * 0.2;
      if (is.stepsDone >= p.steps.length) { t.runs++; closeStop(sim, is, false); settle(sim, is, false); }
    }
  });
  ST.forEach(st => {
    if (sim.pool.some(o => o && o.at === st.id && o.phase === 'working')) return;
    const q = sim.pool.filter(o => o && o.at === st.id && o.phase === 'queued').sort((a, b) => a.qAt - b.qAt)[0];
    if (q) { q.phase = 'working'; q.arr = sim.tick; q.cur.t0 = sim.clock; sim.last[st.id] = { is: q, round: q.round, t1: 0 }; }
  });
  sim.pool.forEach((o, i) => { if (o && o.phase === 'done' && sim.clock - o.doneAt > 330) { sim.gone[o.n] = o; sim.pool[i] = null; } });
}

function promptFor(cfg, is, round) {
  const n = is.n, pr = is.pr;
  if (cfg.id === 'analyst') return 'You are the ADLC Product Analyst. Triage issue #' + n + ' and turn it into stories (or a change brief). Load the product-analyst agent definition and the triage + project-conventions + adlc:edd-spec skills. Do the completeness check first: if the requirement is ambiguous or malformed, post numbered clarifying questions and stop. Otherwise emit an ADLC-TRIAGE verdict line, post the story set or the change brief, and move the issue to gate:stories. Never apply a stage:* label.';
  if (cfg.id === 'architect') return 'You are the ADLC Architect. Design issue #' + n + ': write the ADR under docs/adr/ and post the task breakdown, each task with its declared diff scope. Load the architect agent definition and the project-conventions + release-ops skills. When both exist, move the issue to stage:build. Never write outside docs/.';
  if (cfg.id === 'builder') {
    if (round) return 'You are the ADLC Builder. PR #' + pr + ' was labelled adlc:changes-requested. Read the architect + adversarial review comments on the PR, fix the issues within the declared diff scope, keep the AC-traced tests green, commit with a message starting adlc-fix: and push to the same branch. Do not merge, do not change labels.';
    if (is.lane === 'fast') return 'You are the ADLC Builder on the fast lane. Implement the change brief on issue #' + n + ' and stay inside the size cap. Load the builder agent definition and the project-conventions + adlc:security-gate skills. Open a PR labelled lane:fast; never merge.';
    return 'You are the ADLC Builder. Implement issue #' + n + ' following its task breakdown and ADR. Load the builder agent definition and the project-conventions + adlc:security-gate skills. Open a PR; never merge.';
  }
  if (cfg.id === 'reviewer') return 'You are the ADLC adversarial-reviewer. Review PR #' + pr + ' in fresh context, read-only, seeing only the diff + the linked ADR/task breakdown/ACs. Load the adversarial-reviewer agent definition + adlc:code-review + project-conventions + adlc:security-gate. Apply the three pillars. Post findings as one PR comment whose last line is exactly ADLC-ADV: PASS or ADLC-ADV: CHANGES. Never edit code, never merge, never change labels.';
  return 'You are ADLC QA & Release/Ops. Gate the PR linked to issue #' + n + '. Load the qa-release-ops agent definition and the project-conventions + adlc:edd-spec + adlc:security-gate + release-ops skills. Verify AC coverage, run the full test battery (paste real output), run the adversarial security gate. On a clean verdict, add gate:deploy and post a Proposed Action Card. Never merge, never deploy.';
}
function payloadFor(cfg, is, round, repo, t0) {
  let ev;
  if (cfg.id === 'reviewer') ev = { event: round ? 'pull_request.synchronize' : 'pull_request.opened', repository: repo.name, pull_request: is.pr, issue: is.n, sender: 'builder' };
  else if (cfg.id === 'builder' && round) ev = { event: 'pull_request.labeled', repository: repo.name, pull_request: is.pr, issue: is.n, label: 'adlc:changes-requested', sender: 'review lane' };
  else ev = { event: 'issues.labeled', repository: repo.name, issue: is.n, label: cfg.id === 'builder' && is.lane === 'fast' ? 'stage:fast' : cfg.trigger, sender: cfg.id === 'analyst' ? 'you' : cfg.id === 'architect' ? (is.autopilot ? 'autopilot' : 'you') : cfg.id === 'builder' ? (is.lane === 'fast' ? 'you' : 'architect') : 'review lane' };
  ev.lane = is.lane; ev.runner = 'this machine'; ev.agent = cfg.id; ev.model = cfg.model; ev.session = sid(is.n, cfg.i, round); ev.started = fClock(t0);
  return JSON.stringify(ev, null, 2);
}
function outputsFor(cfg, is, round) {
  const n = '#' + is.n, fast = is.lane === 'fast', pr = 'PR #' + is.pr;
  if (cfg.id === 'analyst') return [
    { at: 3, icon: 'tag', title: 'Triage verdict', meta: 'A recommendation only. You choose the lane at Gate 1.', code: fast ? 'ADLC-TRIAGE: FAST | one small change, no design needed' : 'ADLC-TRIAGE: FULL | more than one area, needs a design' },
    { at: 5, icon: 'msg', title: fast ? 'Change brief on ' + n : 'Story set on ' + n, meta: fast ? 'Change, scope, one acceptance check and what is out of scope.' : is.stories + ' stories, ' + is.acs + ' acceptance checks, edge cases and an out-of-scope list.' },
    { at: 6, icon: 'tag', title: 'Label moved', meta: 'The issue now waits for you.', code: 'stage:intake -> gate:stories' }];
  if (cfg.id === 'architect') return [
    { at: 3, icon: 'file', title: 'docs/adr/' + pad(is.adr, 4) + '-' + is.slug + '.md', meta: 'Decision, alternatives and consequences. Blast radius check: parallel-safe.' },
    { at: 4, icon: 'list', title: 'Task breakdown on ' + n, meta: '3 ordered tasks, each with the exact files the Builder may touch.' },
    { at: 6, icon: 'tag', title: 'Label moved', meta: 'This starts the Builder.', code: 'stage:design -> stage:build' }];
  if (cfg.id === 'builder') return round ? [
    { at: 1, icon: 'pencil', title: 'Fix for the High finding', meta: 'Changed inside the allowed files only.' },
    { at: 2, icon: 'okc', title: 'Tests', meta: 'Pasted from the real run.', code: is.tests + 1 + ' passed in 5.02s' },
    { at: 3, icon: 'branch', title: 'Commit pushed to ' + pr, meta: 'The push starts the review again.', code: 'adlc-fix: address review round ' + round }] : [
    { at: 1, icon: 'branch', title: 'Branch', meta: 'Never main.', code: 'feat/' + is.n + '-' + is.slug },
    { at: 4, icon: 'okc', title: 'Tests', meta: 'One test for each acceptance check. Pasted from the real run.', code: is.tests + ' passed in 4.81s' },
    { at: 6, icon: 'shield', title: 'Diff scope', meta: is.files === 1 ? 'The one changed file is inside the declared scope.' : is.files + ' of ' + is.files + ' changed files are inside the declared scope.' },
    { at: 7, icon: 'pr', title: 'Pull request ' + (is.pr ? '#' + is.pr : ''), meta: 'Written for a reviewer with no session context.' }];
  if (cfg.id === 'reviewer') {
    const changes = round < is.fixes;
    const rows = [
      { at: 5, icon: 'spark', title: 'Structured disagreement', meta: 'The strongest case that the change is wrong was written down, tested against the code, and ' + (changes ? 'confirmed.' : 'dismissed with evidence.') },
      { at: 6, icon: changes ? 'alert' : 'okc', title: changes ? '1 High finding on ' + pr : 'No blocking findings on ' + pr, meta: changes ? 'A concrete failing input and the wrong result it gives.' : 'A clean review, after a real attempt to break it.', code: changes ? 'ADLC-FINDING: High | missing-authz | src/' + is.slug.split('-')[0] + '/handler.ts\nADLC-ADV: CHANGES' : 'ADLC-ADV: PASS' }];
    if (fast) rows.push({ at: 6, icon: 'shield', title: 'Size cap', meta: is.files + ' files and ' + is.lines + ' lines. Inside the 5 file, 40 line limit, and no sensitive path touched.' });
    else if (!changes) rows.push({ at: 6, icon: 'plan', title: 'Architect design check', meta: 'The diff matches the ADR and stays inside the declared scope.', code: 'ADLC-ARCH: PASS' });
    return rows;
  }
  return [
    { at: 1, icon: 'list', title: 'Acceptance coverage', meta: is.acs + ' of ' + is.acs + ' checks have a test. 1 missing test written.' },
    { at: 3, icon: 'okc', title: 'Test battery', meta: 'Pasted from the real run.', code: is.suite + ' passed, 0 failed in 38.2s' },
    { at: 4, icon: 'shield', title: 'Security gate', meta: 'No Critical or High finding.' },
    { at: 5, icon: 'card', title: 'Proposed Action Card', meta: 'The merge proposal you read at Gate 2.', code: 'Action:     merge PR #' + is.pr + ' to main\nRisk:       low\nMigrations: additive\nRollback:   revert the merge commit\nAwaiting:   Principal approval' },
    { at: 6, icon: 'tag', title: 'Label moved', meta: 'The pull request now waits for you.', code: 'stage:qa -> gate:deploy' }];
}
function handTo(cfg, is, round) { return cfg.id === 'analyst' ? 'Gate 1' : cfg.id === 'architect' ? 'the Builder' : cfg.id === 'builder' ? 'the Reviewer' : cfg.id === 'qa' ? 'Gate 2' : round < is.fixes ? 'the Builder for a fix' : is.lane === 'fast' ? 'Gate 2' : 'QA'; }
function reportFor(cfg, is, round) {
  const n = '#' + is.n;
  if (cfg.id === 'analyst') return is.lane === 'fast' ? 'Verdict: FAST.\nOne change, ' + is.files + ' file(s), no sensitive path.\nOpen questions: 0. ' + n + ' is at gate:stories.' : 'Verdict: FULL.\n' + is.stories + ' stories, ' + is.acs + ' acceptance checks.\nOpen questions: 0. ' + n + ' is at gate:stories.';
  if (cfg.id === 'architect') return 'ADR ' + pad(is.adr, 4) + ' written, status Proposed.\n3 tasks posted, every task has a diff scope.\nBlast radius: parallel-safe. ' + n + ' is at stage:build.';
  if (cfg.id === 'builder') return round ? 'Fix round ' + round + ' pushed to PR #' + is.pr + '.\nTests: ' + (is.tests + 1) + ' passed in 5.02s\nLabels left unchanged.' : 'Branch feat/' + is.n + '-' + is.slug + ', PR #' + is.pr + '.\nFiles touched: ' + is.files + ', all inside the declared scope.\nTests: ' + is.tests + ' passed in 4.81s\nReady for review. Labels left unchanged.';
  if (cfg.id === 'reviewer') return round < is.fixes ? 'CHANGES REQUESTED on PR #' + is.pr + '.\n1 High finding, with its failing input.\nADLC-ADV: CHANGES' : 'PASS on PR #' + is.pr + '.\nNo Critical or High finding.\nADLC-ADV: PASS';
  return 'QA verdict: approved.\n' + is.suite + ' passed, 0 failed. ' + is.acs + ' of ' + is.acs + ' checks covered.\nSecurity gate clean. Action card posted. ' + n + ' is at gate:deploy.';
}

// ---------------------------------------------------------------------------------------------
// Adapter: simulator -> the state document
export function createDemo(meta) {
  const agents = {};
  ((meta && meta.stations) || []).forEach(a => { agents[a.station] = a; });
  let key = 'storefront', sim = seed(key);
  const d0 = new Date(); d0.setHours(0, 0, 0, 0);
  const day0 = d0.getTime() / 1000;
  const ep = clock => day0 + clock;

  function runOf(st) {
    const all = sim.pool.filter(Boolean);
    const act = all.find(o => o.at === st.id && o.phase === 'working'), last = sim.last[st.id];
    const r = act ? { is: act, round: act.round, live: true, t1: 0 } : last ? { is: last.is, round: last.round, live: false, t1: last.t1 || sim.clock } : null;
    if (!r) return null;
    const is = r.is, p = plan(st, is.n, r.round), K = p.steps.length, done = r.live ? is.stepsDone : K;
    const t0 = r.live ? sim.clock - is.el : r.t1 - p.total;
    const shown = Math.min(K, done + (r.live ? 1 : 0));
    const steps = p.steps.slice(0, shown).map((s, i) => ({ kind: s.kind, label: fill(s.label, is), t0: ep(t0 + (i ? p.steps[i - 1].cum : 0)), t1: i < done ? ep(t0 + s.cum) : null, ok: true, tok: i < done ? s.tok : null }));
    const k = Math.min(done, K - 1), s = p.steps[k], agent = agents[st.id] || {};
    const skillsTok = st.skills.reduce((a, x) => a + x[1], 0);
    const ctx = [
      { id: 'agent', name: 'System prompt: the agent definition', tok: st.agentTok, cached: true, est: false, detail: 'The agent file is this agent’s whole system prompt. It ships with the plugin, so it is shown in full.', items: [{ name: st.file, tok: st.agentTok }], text: agent.prompt || '' },
      { id: 'sys', name: 'Tool definitions and environment block', tok: st.sysTok, cached: true, est: false, detail: 'Added by Claude Code around the agent prompt: the schema of each allowed tool, and a short block with the working directory and git status. Their size is measured. The text is not exported.', items: ((agents[st.id] || {}).tools || []).map(x => ({ name: x, tok: null })), text: '' },   // the real list, from /api/meta
      { id: 'skills', name: st.skills.length + ' skills', tok: skillsTok, cached: true, est: false, detail: 'Loaded once and frozen for the whole run.', items: st.skills.map(x => ({ name: x[0], tok: x[1] })), text: '' },
      { id: 'claude', name: 'CLAUDE.md', tok: CLAUDE_TOK, cached: true, est: false, detail: 'The project file: commands, gotchas and pointers.', items: [], text: '' },
      { id: 'conv', name: 'This run so far', tok: s.cacheRead - st.prefix, cached: true, est: false, detail: 'The task prompt, then every tool call and result up to the previous step.', items: p.steps.slice(0, k).map(x => ({ name: fill(x.label, is), tok: x.input + x.output })), text: '' },
      { id: 'new', name: 'New in this step', tok: s.input, cached: false, est: false, detail: 'The newest input. It is billed at the full input price once, then joins the cache.', items: [{ name: fill(s.label, is), tok: s.input }], text: '' }
    ].filter(x => x.tok > 0);
    const outs = outputsFor(st, is, r.round), ready = outs.filter(o => done > o.at);
    const acc = { tok: 0, usd: 0, input: 0, cacheRead: 0, output: 0, steps: 0 };
    p.steps.slice(0, done).forEach(x => addStep(acc, x));
    return {
      id: 'demo-' + st.id, station: st.id, n: is.n, title: is.title, round: r.round, live: r.live, t0: ep(t0), t1: r.live ? null : ep(r.t1), session: sid(is.n, st.i, r.round), model: st.model,
      steps, stepCount: steps.length, total: K, prompt: promptFor(st, is, r.round), payload: JSON.parse(payloadFor(st, is, r.round, REPOS[key], t0)),
      ctx, ctxTotal: s.cacheRead + s.input,
      prefixNote: 'The first four parts are the cached prefix: ' + fTok(st.prefix) + ' tokens, fingerprint ' + st.fp + ', unchanged for ' + sim.today[st.id].runs + ' runs today.',
      outputs: ready.map(o => ({ icon: o.icon, title: o.title, meta: o.meta || '', code: o.code || '' })),
      headline: r.live ? (ready.length ? ready.length + ' of ' + outs.length + ' outputs ready. Still working.' : 'Nothing handed off yet. Still working.') : 'Handed off to ' + handTo(st, is, r.round) + ' at ' + fClock(r.t1),
      report: r.live ? '' : reportFor(st, is, r.round),
      replies: p.steps.slice(0, done).map(x => ({ input: x.input, output: x.output, cacheRead: x.cacheRead, usd: x.usd, ms: sim.lat[st.id] * 1000 })), acc
    };
  }

  function state() {
    const repo = REPOS[key], all = sim.pool.filter(Boolean);
    const requests = all.map(is => {
      let t = ep(is.born);
      const stops = is.hist.map(h => { const o = { slot: h.slot, round: h.round, t0: t, t1: t + h.sec, tok: h.tok, usd: h.usd, steps: h.steps, note: h.note, auto: !!h.auto }; t += h.sec; return o; });
      stops.push({ slot: is.at, round: is.round, t0: is.phase === 'done' ? ep(is.doneAt) : t, t1: null, tok: is.cur.tok, usd: is.cur.usd, steps: is.cur.steps, note: '', auto: false });
      const built = is.hist.some(h => h.slot === 'builder'), atB = is.at === 'builder' && is.phase === 'working' && is.round === 0;
      const tDone = built ? 3 : atB ? Math.min(2, Math.max(0, is.stepsDone - 3)) : 0, area = repo.areas[is.epic] || 'app';
      const tasks = is.lane === 'full' && is.hist.some(h => h.slot === 'architect')
        ? [['Data and storage', 'db/migrations/, src/models/'], ['Server logic and its tests', 'src/' + area + '/, tests/' + area + '/'], ['Screen and copy', 'web/' + area + '/']].map((x, i) => ({ title: 'Task ' + (i + 1) + ': ' + x[0], scope: 'Allowed files: ' + x[1], state: i < tDone ? 'done' : atB && i === tDone ? 'now' : 'todo' }))
        : null;
      return { n: is.n, title: is.title, url: '', epic: is.epic, lane: is.lane, fastRec: is.lane === 'fast' && is.at === 'gate1', autopilot: is.autopilot, at: is.at, phase: is.phase,
        since: is.phase === 'working' ? ep(sim.clock - is.el) : is.phase === 'done' ? ep(is.doneAt) : ep(is.cur.t0), born: ep(is.born), doneAt: is.phase === 'done' ? ep(is.doneAt) : null,
        pr: is.pr, adr: is.adr, round: is.round, alert: '', stops, tasks };
    });
    const stations = {};
    ST.forEach(st => {
      const t = sim.today[st.id];
      stations[st.id] = { today: { tok: t.tok, usd: t.usd, input: t.input, cacheRead: t.cacheRead, output: t.output, steps: t.steps, runs: t.runs }, lat: sim.lat[st.id],
        queued: all.filter(o => o.at === st.id && o.phase === 'queued').length, run: runOf(st) };
    });
    const lead = sim.lead.slice().sort((a, b) => a - b)[Math.floor(sim.lead.length / 2)];
    return { v: 1, mode: 'demo', now: ep(sim.clock), repo: repo.name,
      repos: Object.keys(REPOS).map(k => ({ name: REPOS[k].name, count: k === key ? all.filter(o => o.phase !== 'done').length : 7 })),
      github: { ok: true, msg: '', polled: null }, telemetry: true,
      epics: Object.keys(repo.epics).map(k => ({ key: k, name: repo.epics[k] })), merged: sim.merged, lead, stations, requests,
      feed: sim.feed.map(e => ({ t: ep(e.t), who: e.who, n: e.n, text: e.text })) };
  }

  return {
    tick: speed => tick(sim, speed || 1),
    state,
    pick: name => { const k = Object.keys(REPOS).find(x => REPOS[x].name === name); if (k && k !== key) { key = k; sim = seed(key); } }
  };
}
