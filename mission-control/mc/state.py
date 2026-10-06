"""Builds the one document the screen renders: where every request is, what each station is doing, and what it cost.

GitHub is the source of truth for where a request stands (labels, pull requests, verdict comments).
Hook events say what an agent is doing right now. Telemetry says what it cost.
"""
import os
import time

from . import pipeline as P

LIVE_GAP = 600      # seconds without any event before a run stops counting as working
LONG_GAP = 1800     # the same while a tool call is open: a long test run or a helper agent sends nothing until it ends
RUN_WINDOW = 7 * 86400
DAY = 86400

SLOT_NAME = {'intake': 'intake', 'analyst': 'the Analyst', 'gate1': 'Gate 1', 'architect': 'the Architect', 'builder': 'the Builder',
             'reviewer': 'review', 'qa': 'QA', 'gate2': 'Gate 2', 'done': 'main'}


def midnight(now):
    t = time.localtime(now)
    return time.mktime((t.tm_year, t.tm_mon, t.tm_mday, 0, 0, 0, 0, 0, -1))


def _group(rows, key):
    out = {}
    for r in rows:
        out.setdefault(r[key], []).append(r)
    return out


def _last(regex, texts):
    """The last match of a verdict marker across comment bodies, as (value, comment) or (None, None)."""
    found = (None, None)
    for c in texts:
        hits = regex.findall(c['body'] or '')
        if hits:
            found = (hits[-1], c)
    return found


def build(store, repo, now=None, agents=None, github=None, mode='live', plugin_root=None):
    now = now or time.time()
    day0 = midnight(now)
    agents = agents or {}
    issues = store.issues(repo)
    events = _group(store.label_events(repo), 'number')
    prs = store.prs(repo)
    prs_by_issue = _group([p for p in prs if p.get('issue')], 'issue')
    comments = {}
    for c in store.comments(repo):
        comments.setdefault((c['kind'], c['number']), []).append(c)
    runs = store.runs_in(repo, now - RUN_WINDOW)
    open_step = store.runs_with_open_step()
    for r in runs:
        r['open_step'] = r['id'] in open_step

    requests = []
    for issue in issues:
        req = _request(store, issue, events.get(issue['number'], []), prs_by_issue.get(issue['number'], []), comments, runs, now, day0)
        if req:
            requests.append(req)
    _claim_unassigned(requests, runs, now)
    requests.sort(key=lambda r: r['n'])
    by_n = {r['n']: r for r in requests}

    stations = {}
    for st in P.STATIONS:
        st_runs = [r for r in runs if r['station'] == st]
        ids = [r['id'] for r in st_runs]
        total = store.api_sum(ids, t0=day0)
        steps = 0
        if ids:
            marks = ', '.join('?' for _ in ids)
            steps = store.one('SELECT COUNT(*) AS n FROM steps WHERE started >= ? AND run IN (%s)' % marks, [day0] + ids)['n']
        live = [r for r in st_runs if _is_live(r, now)]
        pick = (live or st_runs)[-1] if (live or st_runs) else None
        stations[st] = {
            'today': {'tok': total['tok'], 'usd': total['usd'], 'input': total['input'] + total['cacheCreation'], 'cacheRead': total['cacheRead'],
                      'output': total['output'], 'steps': steps, 'runs': len([r for r in st_runs if r['started'] >= day0])},
            'lat': (total['ms'] / total['replies'] / 1000.0) if total['replies'] else None,
            # Requests here that no run on this machine is working on. Their agent may be running elsewhere (a lane on GitHub).
            'queued': len([r for r in requests if r['at'] == st and r['phase'] == 'queued']),
            'run': _run_detail(store, pick, by_n, agents.get(st) or {}, repo, comments, events, prs, now, plugin_root) if pick else None,
        }

    epics, seen = [], set()
    for r in requests:
        if r['epic'] not in seen:
            seen.add(r['epic'])
            epics.append({'key': r['epic'], 'name': r['epic'] or 'No milestone'})
    tel = store.meta('telemetry') or {}
    return {
        'v': 1, 'mode': mode, 'now': now, 'repo': repo,
        'repos': [{'name': name, 'count': _on_line(store, name)} for name in store.repos()],
        'github': github or {'ok': True, 'msg': '', 'polled': None},
        # Whether Claude Code's telemetry reaches us at all, from any session. Whether a given run has figures is a separate matter.
        'telemetry': now - (tel.get('seen') or 0) < DAY,
        'telemetryNote': ('Model replies from plugin agents are arriving without the agent’s name, so they cannot be placed on a run. '
                          'Add OTEL_LOG_TOOL_DETAILS=1 to the same settings block.') if now - (tel.get('unnamed') or 0) < DAY else '',
        'epics': epics,
        'merged': len([r for r in requests if r['phase'] == 'done']),
        'lead': _lead(events),
        'stations': stations,
        'requests': requests,
        'feed': _feed(events, prs, comments, runs, day0),
    }


def _on_line(store, repo):
    return len([i for i in store.issues(repo) if i['state'] == 'OPEN' and P.slot_for_labels(i['labels'])[0]])


def _is_live(run, now):
    quiet = now - (run.get('last_seen') or 0)
    return not run.get('ended') and quiet < (LONG_GAP if run.get('open_step') else LIVE_GAP)


def _serves(run, slot):
    """Whether a run is work for a slot. The Architect has two duties: a run of it that names a pull request is its review of that pull request."""
    if run['station'] == 'architect':
        return slot == ('reviewer' if run.get('pr') else 'architect')
    return run['station'] == slot


# ---------------------------------------------------------------------------------------- requests
def _request(store, issue, evs, pr_list, comments, runs, now, day0):
    n, labels = issue['number'], issue['labels']
    slot, label = P.slot_for_labels(labels, evs)
    pr_list = sorted(pr_list, key=lambda p: p.get('created') or 0)
    open_prs = [p for p in pr_list if p['state'] == 'OPEN']
    merged_prs = [p for p in pr_list if p.get('merged')]
    pr = (open_prs or merged_prs or pr_list or [None])[-1]
    on_line_before = any(e['added'] and e['label'] in P.LABEL_SLOT for e in evs)
    done_at = None
    if issue['state'] == 'CLOSED':
        if not (merged_prs and (on_line_before or slot)):
            return None
        done_at = merged_prs[-1]['merged']
    elif slot is None:
        return None
    elif merged_prs and not open_prs:
        # Merged, but nothing closed the issue (no closing keyword). The line is done with it, unless a label moved it again afterwards.
        moved = max([e['ts'] for e in evs if e['added'] and e['label'] == label and e.get('ts')] or [0])
        if merged_prs[-1]['merged'] >= moved:
            done_at = merged_prs[-1]['merged']
    if done_at is not None:
        if done_at < day0:
            return None
        slot = 'done'

    icomments = comments.get(('issue', n), [])
    pcomments = comments.get(('pr', pr['number']), []) if pr else []
    timeline, rounds = _timeline(evs, pr, pcomments, done_at)
    if slot == 'builder' and pr and pr['state'] == 'OPEN':
        slot = timeline[-1]['slot'] if timeline and timeline[-1]['slot'] in ('builder', 'reviewer') else 'reviewer'
        if 'adlc:changes-requested' in pr['labels']:
            slot = 'builder'
    if not timeline or timeline[-1]['slot'] != slot:
        timeline.append({'ts': (timeline[-1]['ts'] if timeline else issue.get('updated') or issue.get('created') or now), 'slot': slot, 'round': rounds})

    triage, _ = _last(P.TRIAGE_RE, icomments)
    my_runs = [r for r in runs if r.get('issue') == n or (pr and r.get('pr') == pr['number'])]

    stops = []
    for i, tr in enumerate(timeline):
        t1 = timeline[i + 1]['ts'] if i + 1 < len(timeline) else None
        stop = {'slot': tr['slot'], 'round': tr.get('round', 0), 't0': tr['ts'], 't1': t1, 'tok': 0, 'usd': 0.0, 'steps': 0, 'note': '', 'auto': False}
        if tr['slot'] in P.STATIONS:
            ids = [r['id'] for r in my_runs if _serves(r, tr['slot']) and r['started'] >= tr['ts'] - 120 and (t1 is None or r['started'] < t1)]
            total = store.api_sum(ids)
            stop.update({'tok': total['tok'], 'usd': total['usd'], 'steps': sum(store.step_count(i_) for i_ in ids)})
        if t1 is not None:
            nxt = timeline[i + 1]
            stop['note'], stop['auto'] = _note(tr, nxt, pr, icomments, pcomments, labels, t1)
        stops.append(stop)
    if issue.get('created') and stops and stops[0]['t0'] - issue['created'] > 5:
        stops.insert(0, {'slot': 'intake', 'round': 0, 't0': issue['created'], 't1': stops[0]['t0'], 'tok': 0, 'usd': 0.0, 'steps': 0,
                         'note': 'Filed, then labelled stage:intake', 'auto': False})

    # 'queued' means no run on this machine is working on it. Its agent may still be at work elsewhere (a lane on GitHub).
    phase, since = 'queued', timeline[-1]['ts']
    if slot == 'done':
        phase = 'done'
    elif slot in P.GATES:
        phase = 'waiting'
    else:
        live = [r for r in my_runs if _serves(r, slot) and _is_live(r, now)]
        if live:
            phase, since = 'working', live[-1]['started']
    adr = None
    for c in icomments:
        m = P.ADR_RE.search(c['body'] or '')
        if m:
            adr = int(m.group(1))
    return {
        'n': n, 'title': issue['title'], 'url': issue['url'], 'epic': issue.get('milestone') or '', 'lane': _lane(labels, evs, pr),
        'fastRec': triage == 'FAST' and slot == 'gate1', 'autopilot': 'adlc:autopilot' in labels, 'at': slot, 'phase': phase,
        'since': since, 'born': issue.get('created') or since, 'doneAt': done_at, 'pr': pr['number'] if pr else None, 'adr': adr,
        'round': rounds, 'alert': 'Needs a human' if (pr and 'needs:human' in pr['labels']) else '', 'stops': stops,
    }


def _lane(labels, evs, pr):
    """Fast only while the fast lane still has it. A request bounced to the full pipeline (stage:fast, then stage:design) is a full one."""
    if pr and 'lane:fast' in pr['labels']:
        return 'fast'
    routed = [e['label'] for e in evs if e['added'] and e['label'] in ('stage:fast', 'stage:design', 'stage:build')]
    if routed:
        return 'fast' if routed[-1] == 'stage:fast' else 'full'
    return 'fast' if 'stage:fast' in labels else 'full'


def _review(comments):
    """What one review left on the pull request: its last ADLC-ADV and ADLC-ARCH verdicts, and when the last one was posted."""
    adv = arch = at = None
    for c in comments:
        a, b = P.ADV_RE.findall(c['body'] or ''), P.ARCH_RE.findall(c['body'] or '')
        adv, arch = (a[-1] if a else adv), (b[-1] if b else arch)
        if a or b:
            at = c['ts']
    return adv, arch, at


def _timeline(evs, pr, pcomments, done_at):
    """Every move of a request, in order: label changes, the pull request opening, and each fix round.

    A fix round is what the lanes make it. A review that is not clean on both verdicts sends the pull request to
    the Builder, and the Builder's `adlc-fix:` commit sends it back to review. So there is one round per fix commit
    (the count adlc-fix-cap.sh caps), plus one more while a review's request for changes is still unanswered.
    """
    t = [{'ts': e['ts'], 'slot': P.LABEL_SLOT[e['label']], 'round': 0, 'actor': e.get('actor'), 'label': e['label']}
         for e in evs if e['added'] and e['label'] in P.LABEL_SLOT and e.get('ts')]
    rounds = 0
    if pr and pr.get('created'):
        starts = [pr['created']] + sorted(f for f in (pr.get('fix_commits') or []) if f > pr['created'])
        ordered = sorted((c for c in pcomments if c.get('ts')), key=lambda c: c['ts'])
        for i, start in enumerate(starts):
            end = starts[i + 1] if i + 1 < len(starts) else None
            t.append({'ts': start, 'slot': 'reviewer', 'round': i})
            adv, arch, at = _review([c for c in ordered if c['ts'] >= start and (end is None or c['ts'] < end)])
            # A fix commit followed, so this review asked for one. For the latest review, read its verdicts. At the cap
            # (needs:human) the loop has stopped and a person takes over: no further round.
            if end is not None or ('CHANGES' in (adv, arch) and 'needs:human' not in pr['labels']):
                rounds = i + 1
                t.append({'ts': at or end, 'slot': 'builder', 'round': rounds})
    if done_at:
        t.append({'ts': done_at, 'slot': 'done', 'round': rounds})
    t.sort(key=lambda x: x['ts'])
    out = []
    for tr in t:
        if out and out[-1]['slot'] == tr['slot'] and out[-1].get('round', 0) == tr.get('round', 0):
            continue
        out.append(tr)
    return out, rounds


def _note(tr, nxt, pr, icomments, pcomments, labels, t1):
    """One plain line on what a finished stop produced, and whether autopilot made the call."""
    slot, t0 = tr['slot'], tr['ts']
    inside = lambda cs: [c for c in cs if t0 - 5 <= (c['ts'] or 0) <= t1 + 180]
    prn = ('PR #%d' % pr['number']) if pr else 'the pull request'
    if nxt.get('label') and P.SLOTS.index(nxt['slot']) < P.SLOTS.index(slot):
        # A label moved it to an earlier stage (stories returned, QA re-run). A fix round is not this: it carries no label.
        return 'Sent back to %s%s' % (SLOT_NAME[nxt['slot']], ' by ' + nxt['actor'] if nxt.get('actor') else ''), False
    if slot == 'analyst':
        verdict, _ = _last(P.TRIAGE_RE, inside(icomments))
        if verdict == 'FAST':
            return 'Change brief posted. ADLC-TRIAGE: FAST', False
        return ('Stories posted. ADLC-TRIAGE: FULL' if verdict == 'FULL' else 'Posted on the issue'), False
    if slot == 'gate1':
        if 'adlc:autopilot' in labels and nxt.get('label') == 'stage:design' and t1 - t0 < 180:
            return 'Autopilot approved the plan', True
        who = nxt.get('actor') or 'you'
        return ('Fast lane approved by %s' if nxt.get('label') == 'stage:fast' else 'Plan approved by %s') % who, False
    if slot == 'architect':
        for c in inside(icomments):
            m = P.ADR_RE.search(c['body'] or '')
            if m:
                return 'ADR %04d and the task breakdown' % int(m.group(1)), False
        return 'Design and task breakdown', False
    if slot == 'builder':
        return ('Pushed fix round %d to %s' % (tr.get('round', 0), prn) if tr.get('round') else 'Opened ' + prn), False
    if slot == 'reviewer':
        adv, _ = _last(P.ADV_RE, inside(pcomments))
        arch, _ = _last(P.ARCH_RE, inside(pcomments))
        parts = ['ADLC-ADV: ' + adv] if adv else []
        parts += ['ADLC-ARCH: ' + arch] if arch else []
        return (' and '.join(parts) or 'Review posted'), False
    if slot == 'qa':
        carded = any(P.ACTION_CARD_RE.search(c['body'] or '') for c in inside(icomments) + inside(pcomments))
        return ('Checks passed. Action card posted' if carded else 'QA verdict posted'), False
    if slot == 'gate2':
        return 'Merged ' + prn, False
    return '', False


def _claim_unassigned(requests, runs, now):
    """A live run whose issue could not be read still shows as working when only one request sits at its station."""
    for st in P.STATIONS:
        live = [r for r in runs if r['station'] == st and _is_live(r, now) and r.get('issue') is None and r.get('pr') is None]
        here = [r for r in requests if r['at'] == st]
        if live and len(here) == 1 and here[0]['phase'] == 'queued':
            here[0]['phase'], here[0]['since'] = 'working', live[-1]['started']
            live[-1]['issue'] = here[0]['n']


# ---------------------------------------------------------------------------------------- runs
def _run_detail(store, run, by_n, agent, repo, comments, events, prs, now, plugin_root=None):
    live = _is_live(run, now)
    req = by_n.get(run.get('issue'))
    if req is None and run.get('pr'):
        req = next((r for r in by_n.values() if r.get('pr') == run['pr']), None)
    steps = store.steps(run['id'])
    replies = store.api_rows(run['id'])
    acc = store.api_sum([run['id']])
    t1 = run.get('ended') or (None if live else run.get('last_seen'))
    prompt = run.get('prompt') or ''

    ctx = []
    if agent.get('prompt'):
        ctx.append({'id': 'agent', 'name': 'System prompt: the agent definition', 'tok': P.est_tokens(len(agent['prompt'])), 'cached': True, 'est': True,
                    'detail': 'The agent file is this agent’s whole system prompt. It ships with the plugin, so it is shown in full.',
                    'items': [{'name': agent.get('file', ''), 'tok': P.est_tokens(len(agent['prompt']))}], 'text': agent['prompt']})
    skills = [{'name': name, 'tok': P.skill_tokens(plugin_root, run.get('cwd'), name)} for name in store.step_values(run['id'], 'skill')]
    if skills:
        ctx.append({'id': 'skills', 'name': '%d skill%s loaded' % (len(skills), '' if len(skills) == 1 else 's'), 'tok': sum(s.get('tok') or 0 for s in skills),
                    'cached': True, 'est': True, 'detail': 'Loaded with the Skill tool during this run. Sizes are estimates from the skill files.',
                    'items': skills, 'text': ''})
    claude_md = _file_size(os.path.join(run.get('cwd') or '', 'CLAUDE.md'))
    if claude_md:
        ctx.append({'id': 'claude', 'name': 'CLAUDE.md', 'tok': P.est_tokens(claude_md), 'cached': True, 'est': True,
                    'detail': 'The project file: commands, gotchas and pointers.', 'items': [], 'text': ''})
    if prompt:
        ctx.append({'id': 'task', 'name': 'Task prompt', 'tok': P.est_tokens(len(prompt)), 'cached': True, 'est': True,
                    'detail': 'What this run was asked to do. Shown in full below.', 'items': [], 'text': ''})
    ctx_total = None
    if replies:
        last = replies[-1]
        fresh = (last['input'] or 0) + (last['cache_creation'] or 0)
        cached = last['cache_read'] or 0
        ctx_total = fresh + cached
        known = sum(c['tok'] for c in ctx)
        if known <= cached:
            rest, new = cached - known, fresh
        else:
            # A cold or half-warm cache: the parts above were sent as new input this time, so they are inside `fresh`, not beside it.
            for c in ctx:
                c['cached'] = False
            rest, new = 0, max(0, ctx_total - known)
        if rest:
            ctx.append({'id': 'rest', 'name': 'Tool definitions, environment and the run so far', 'tok': rest, 'cached': True, 'est': False,
                        'detail': 'Everything else in the latest request: what Claude Code adds around the agent prompt, plus every tool call and result so far. '
                                  'Measured as the remainder; the text is not exported.', 'items': [], 'text': ''})
        if new:
            ctx.append({'id': 'new', 'name': 'New in the latest reply', 'tok': new, 'cached': False, 'est': False,
                        'detail': 'Input that was not served from cache in the latest request. It is billed at the full price once, then joins the cache.',
                        'items': [], 'text': ''})

    payload = {k: v for k, v in [
        ('agent', run.get('agent_type')), ('model', run.get('model')), ('repository', repo), ('issue', run.get('issue')),
        ('pull_request', run.get('pr')), ('branch', run.get('branch')), ('cwd', run.get('cwd')), ('session', run.get('session')),
        ('started', time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(run['started']))), ('runner', 'this machine'),
    ] if v not in (None, '')}

    return {
        'id': run['id'], 'station': run['station'], 'n': req['n'] if req else run.get('issue'), 'title': req['title'] if req else '',
        'round': _round_of(run, req), 'live': live, 't0': run['started'], 't1': t1, 'session': (run.get('session') or '')[:10],
        'model': run.get('model') or agent.get('model') or '',
        'steps': [{'kind': s['kind'], 'label': s['label'], 't0': s['started'], 't1': s['ended'], 'ok': s['ok'] != 0} for s in steps],
        'stepCount': store.step_count(run['id']), 'total': None,
        'prompt': prompt, 'payload': payload, 'ctx': ctx, 'ctxTotal': ctx_total,
        'outputs': _outputs(run, store.step_values(run['id'], 'path'), req, comments, events, prs, run.get('ended') or (now if live else run.get('last_seen') or run['started'])),
        'report': run.get('report') or '',
        'replies': [{'input': (r['input'] or 0) + (r['cache_creation'] or 0), 'output': r['output'] or 0, 'cacheRead': r['cache_read'] or 0,
                     'usd': r['cost'] or 0.0, 'ms': r['ms'] or 0.0} for r in replies],
        'acc': {'tok': acc['tok'], 'usd': acc['usd'], 'input': acc['input'] + acc['cacheCreation'], 'cacheRead': acc['cacheRead'], 'output': acc['output']},
    }


def _round_of(run, req):
    """The fix round a run belongs to: that of the stop it started in. Only the Builder and the review have rounds."""
    for stop in reversed(req['stops'] if req else []):
        if stop['slot'] in ('builder', 'reviewer') and _serves(run, stop['slot']) and run['started'] >= stop['t0'] - 120:
            return stop['round']
    return 0


def _file_size(path):
    try:
        return os.path.getsize(path)
    except OSError:
        return 0


def _outputs(run, files, req, comments, events, prs, end):
    """What the run left behind: the files it changed, and what appeared on GitHub while it ran (`end` is when it stopped, or now)."""
    out = []
    t0, t1 = run['started'] - 5, end + 180
    cwd = (run.get('cwd') or '').rstrip('/') + '/'
    if files:
        shown = [f[len(cwd):] if f.startswith(cwd) else f for f in files[:8]]
        out.append({'icon': 'pencil', 'title': '%d file%s changed' % (len(files), '' if len(files) == 1 else 's'),
                    'meta': 'Written or edited during this run.', 'code': '\n'.join(shown) + ('\n…' if len(files) > 8 else '')})
    if not req:
        return out
    n, prn = req['n'], req.get('pr')
    inside = lambda cs: [c for c in cs if t0 <= (c['ts'] or 0) <= t1]
    icoms, pcoms = inside(comments.get(('issue', n), [])), inside(comments.get(('pr', prn), [])) if prn else []
    station = run['station']
    if station == 'analyst':
        verdict, c = _last(P.TRIAGE_RE, icoms)
        if verdict:
            out.append({'icon': 'tag', 'title': 'Triage verdict', 'meta': 'A recommendation only. You choose the lane at Gate 1.', 'code': _marker_lines(c['body'], 'ADLC-TRIAGE:')})
    if station in ('reviewer', 'architect'):
        for regex, name, tag in ((P.ADV_RE, 'Adversarial review', 'ADLC-ADV:'), (P.ARCH_RE, 'Architect design check', 'ADLC-ARCH:')):
            verdict, c = _last(regex, pcoms)
            if verdict:
                findings = _marker_lines(c['body'], 'ADLC-FINDING:')
                out.append({'icon': 'okc' if verdict == 'PASS' else 'alert', 'title': name + ': ' + verdict, 'meta': 'Posted on PR #%s.' % prn,
                            'code': (findings + '\n' if findings else '') + _marker_lines(c['body'], tag)})
    if station == 'qa':
        for c in icoms + pcoms:
            if P.ACTION_CARD_RE.search(c['body'] or ''):
                out.append({'icon': 'card', 'title': 'Proposed Action Card', 'meta': 'The merge proposal you read at Gate 2.', 'code': _card(c['body'])})
                break
    if station == 'builder' and prn:
        pr = next((p for p in prs if p['number'] == prn), None)
        if pr and t0 <= (pr.get('created') or 0) <= t1:
            out.append({'icon': 'pr', 'title': 'Pull request #%d' % prn, 'meta': pr.get('title') or '', 'code': pr.get('head') or ''})
    for e in events.get(n, []):
        if e['added'] and e['label'] in P.LABEL_SLOT and t0 <= (e['ts'] or 0) <= t1:
            out.append({'icon': 'tag', 'title': 'Label moved', 'meta': 'Applied by %s.' % (e.get('actor') or 'the pipeline'), 'code': e['label']})
    return out


def _marker_lines(body, tag):
    return '\n'.join(line.strip() for line in (body or '').splitlines() if tag in line)


def _card(body):
    lines = (body or '').splitlines()
    start = next((i for i, line in enumerate(lines) if P.ACTION_CARD_RE.search(line)), 0)
    keep = [line.rstrip() for line in lines[start + 1:start + 9] if line.strip() and not line.strip().startswith('```')]
    return '\n'.join(keep)


# ---------------------------------------------------------------------------------------- line-wide
def _lead(events):
    """Median time from stage:intake to gate:deploy over the latest requests that got there."""
    spans = []
    for n, evs in events.items():
        start = next((e['ts'] for e in evs if e['added'] and e['label'] == 'stage:intake'), None)
        end = next((e['ts'] for e in evs if e['added'] and e['label'] == 'gate:deploy'), None)
        if start and end and end > start:
            spans.append((end, end - start))
    spans = [s for _, s in sorted(spans)[-7:]]
    return sorted(spans)[len(spans) // 2] if spans else None


def _feed(events, prs, comments, runs, day0):
    """Today's activity, newest first. The page prints clock times only, so nothing older than midnight belongs here."""
    feed = []
    on_line = set()   # issues that have been on the line at some point; other issues and their pull requests are not ours to report
    for n, evs in events.items():
        for e in evs:
            if e['added'] and e['label'] in P.LABEL_SLOT and e.get('ts'):
                on_line.add(n)
                who = 'gate1' if e['label'] == 'gate:stories' else 'gate2' if e['label'] == 'gate:deploy' else 'github'
                text = ('#%d is waiting for you' % n) if who != 'github' else '%s moved #%d to %s' % (e.get('actor') or 'Someone', n, e['label'])
                feed.append({'t': e['ts'], 'who': who, 'n': n, 'text': text})
    prs = [p for p in prs if p.get('issue') in on_line]
    comments = {k: v for k, v in comments.items() if (k[1] in on_line if k[0] == 'issue' else any(p['number'] == k[1] for p in prs))}
    for p in prs:
        if p.get('created'):
            feed.append({'t': p['created'], 'who': 'builder', 'n': p['issue'], 'text': 'opened PR #%d for #%d' % (p['number'], p['issue'])})
        if p.get('merged'):
            feed.append({'t': p['merged'], 'who': 'you', 'n': p['issue'], 'text': 'PR #%d was merged' % p['number']})
    owner = {('issue', 'ADLC-TRIAGE'): 'analyst', ('pr', 'ADLC-ADV'): 'reviewer', ('pr', 'ADLC-ARCH'): 'architect'}
    for (kind, number), cs in comments.items():
        issue = number if kind == 'issue' else next((p.get('issue') for p in prs if p['number'] == number), None)
        for c in cs:
            body = c['body'] or ''
            for (k, tag), who in owner.items():
                if k == kind and tag + ':' in body:
                    line = _marker_lines(body, tag + ':').splitlines()[-1]
                    feed.append({'t': c['ts'], 'who': who, 'n': issue, 'text': 'posted %s on %s #%d' % (line[:60], 'PR' if kind == 'pr' else 'issue', number)})
            if P.ACTION_CARD_RE.search(body):
                feed.append({'t': c['ts'], 'who': 'qa', 'n': issue, 'text': 'posted the Proposed Action Card on %s #%d' % ('PR' if kind == 'pr' else 'issue', number)})
    for r in runs:
        if r.get('station'):
            feed.append({'t': r['started'], 'who': r['station'], 'n': r.get('issue'), 'text': 'started a run' + (' on #%d' % r['issue'] if r.get('issue') else '')})
    feed = [f for f in feed if (f['t'] or 0) >= day0]
    feed.sort(key=lambda f: -f['t'])
    return feed[:40]
