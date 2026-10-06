"""Turns what Claude Code sends into rows: hook events become runs and steps, telemetry becomes model replies.

Only agent runs that map to a pipeline station are kept. Anything else is dropped on arrival.
"""
import math
import os
import re
import subprocess
import time

from . import pipeline

HANDOFF_TTL = 120   # seconds a prompt handed to a subagent waits for that subagent to start


class Repos:
    """Looks up the GitHub repo and branch of a working directory, with a short cache."""

    def __init__(self, ttl=60):
        self.ttl = ttl
        self.cache = {}

    def lookup(self, cwd):
        if not cwd:
            return None, None
        hit = self.cache.get(cwd)
        if hit and time.time() - hit[0] < self.ttl:
            return hit[1], hit[2]
        repo = parse_remote(_git(cwd, 'remote', 'get-url', 'origin'))
        branch = _git(cwd, 'rev-parse', '--abbrev-ref', 'HEAD')
        self.cache[cwd] = (time.time(), repo, branch)
        return repo, branch


def _git(cwd, *args):
    try:
        out = subprocess.run(['git', '-C', cwd] + list(args), capture_output=True, text=True, timeout=5)
        return out.stdout.strip() if out.returncode == 0 else ''
    except (OSError, subprocess.SubprocessError):
        return ''


_REMOTE_RE = re.compile(r'[:/]([^/:@\s]+)/([^/:@\s]+)$')


def parse_remote(url):
    """A git remote in any form -> 'owner/name', lower-cased (GitHub ignores case in both).

    'git@github.com:Acme/Shop.git', 'https://github.com/acme/shop', 'ssh://git@github.com/acme/shop' and an
    ssh host alias such as 'git@github-work:acme/shop' all give 'acme/shop'.
    """
    url = (url or '').strip().rstrip('/')
    if url.endswith('.git'):
        url = url[:-4]
    m = _REMOTE_RE.search(url)
    return (m.group(1) + '/' + m.group(2)).lower() if m else None


def _text(value):
    return value if isinstance(value, str) else ''


class Ingest:
    def __init__(self, store, repos=None, on_repo=None):
        self.store = store
        self.repos = repos or Repos()
        self.on_repo = on_repo or (lambda repo: None)
        self.handed = {}   # (session, station) -> [(time, task prompt)] handed to subagents that have not started yet

    # ------------------------------------------------------------------ hooks
    def hook(self, ev, now=None):
        """One hook input from Claude Code. Returns True when it changed what the screen shows."""
        now = now or time.time()
        name = _text(ev.get('hook_event_name'))
        session = _text(ev.get('session_id'))
        if not session:
            return False
        station = pipeline.station_for(ev.get('agent_type'))
        tool = _text(ev.get('tool_name'))
        tool_input = ev.get('tool_input') if isinstance(ev.get('tool_input'), dict) else {}

        # A parent session handing work to a pipeline agent: keep the prompt for when that agent starts.
        if name == 'PreToolUse' and tool in ('Task', 'Agent'):
            child = pipeline.station_for(tool_input.get('subagent_type'))
            if child:
                self.handed.setdefault((session, child), []).append((now, _text(tool_input.get('prompt'))))
        if not station:
            return self._end_session(session, now) if name == 'SessionEnd' else False

        agent_id = str(ev['agent_id']) if ev.get('agent_id') else None
        run_id = session + (':' + agent_id if agent_id else '')
        cwd = _text(ev.get('cwd'))
        fields = {'session': session, 'agent_id': agent_id, 'agent_type': _text(ev.get('agent_type')), 'station': station, 'cwd': cwd}
        before = self.store.run(run_id)
        if before is None:
            repo, branch = self.repos.lookup(cwd)
            fields.update({'repo': repo, 'branch': branch, 'issue': pipeline.issue_in_branch(branch)})
            prompt = self._take_handed(session, station, now)
            if prompt:
                fields.update(self._task(prompt, fields['issue']))
            if repo:
                self.on_repo(repo)
        self.store.run_touch(run_id, now, **fields)
        ended = bool(before and before.get('ended'))
        if ended and name in ('UserPromptSubmit', 'PreToolUse', 'SubagentStart', 'SessionStart'):
            self.store.run_set(run_id, ended=None)   # a new turn in the same session: the run is live again. A late result of an old call is not one.

        if name == 'UserPromptSubmit':
            prompt = _text(ev.get('prompt'))
            first = not (before and before.get('prompt'))
            # The first prompt is the task. A later one replaces it only when it names another request; "also add a test" does not.
            if prompt and (first or (ended and pipeline.refs_in(prompt) != (None, None))):
                self.store.run_set(run_id, **self._task(prompt, pipeline.issue_in_branch((before or {}).get('branch') or fields.get('branch'))))
        elif name == 'PreToolUse':
            kind, label = pipeline.step_label(tool, tool_input, cwd)
            path = _text(tool_input.get('file_path') or tool_input.get('notebook_path')) if tool in ('Edit', 'Write', 'MultiEdit', 'NotebookEdit') else ''
            skill = _text(tool_input.get('skill')) if tool == 'Skill' else ''
            self.store.steps_end_stale(run_id)
            self.store.step_open(run_id, _text(ev.get('tool_use_id')) or None, tool, kind, label, path or None, skill or None, now)
        elif name in ('PostToolUse', 'PostToolUseFailure'):
            ok = name == 'PostToolUse'
            use_id = _text(ev.get('tool_use_id')) or None
            if not self.store.step_close(run_id, use_id, tool, now, ok):
                kind, label = pipeline.step_label(tool, tool_input, cwd)
                self.store.step_open(run_id, use_id, tool, kind, label, None, None, now)
                self.store.step_close(run_id, use_id, tool, now, ok)
        elif name in ('Stop', 'SubagentStop'):
            report = ev.get('last_assistant_message')
            updates = {'ended': now}
            if report:
                updates['report'] = report if isinstance(report, str) else str(report)
            self.store.run_set(run_id, **updates)
            self.store.x('UPDATE steps SET ended = ?, ok = 1 WHERE run = ? AND ended IS NULL', (now, run_id))
        elif name == 'SessionEnd':
            self._end_session(session, now)
        return True

    def _take_handed(self, session, station, now):
        """The oldest prompt handed to this station in this session that is still fresh. Two reviewers started by one parent each get their own."""
        queue = [h for h in self.handed.pop((session, station), []) if now - h[0] < HANDOFF_TTL]
        if not queue:
            return ''
        if queue[1:]:
            self.handed[(session, station)] = queue[1:]
        return queue[0][1]

    def _task(self, prompt, branch_issue):
        """The prompt and the request it names. What the prompt says wins over the branch: "Review PR #10" can run
        from a checkout that sits on another request's branch. The branch is the fallback when the prompt names nothing."""
        issue, pr = pipeline.refs_in(prompt)
        if issue is None and pr is None:
            issue = branch_issue
        return {'prompt': prompt, 'issue': issue, 'pr': pr}

    def _end_session(self, session, now):
        changed = False
        for run in self.store.runs_of_session(session):
            if not run.get('ended'):
                self.store.run_set(run['id'], ended=now)
                changed = True
        return changed

    # ------------------------------------------------------------------ telemetry
    def otlp_logs(self, doc, now=None):
        """An OTLP/HTTP JSON logs export. Keeps the api_request events of pipeline runs. Returns how many were stored."""
        now = now or time.time()
        kept = seen = unnamed = 0
        for rl in _dicts(doc.get('resourceLogs')):
            base = _attrs((rl.get('resource') or {}).get('attributes') if isinstance(rl.get('resource'), dict) else None)
            for sl in _dicts(rl.get('scopeLogs')):
                for rec in _dicts(sl.get('logRecords')):
                    attrs = dict(base)
                    attrs.update(_attrs(rec.get('attributes')))
                    event = str(attrs.get('event.name') or _value(rec.get('body')) or '')
                    if not event.endswith('api_request'):
                        continue
                    seen += 1
                    ts = _nanos(rec.get('timeUnixNano') or rec.get('observedTimeUnixNano')) or now
                    if attrs.get('agent.name') == 'custom':
                        unnamed += 1
                    kept += 1 if self._api(attrs, ts) else 0
        if seen:
            note = self.store.meta('telemetry') or {}
            # Kept so the page can tell "telemetry is off" from "telemetry arrives, but not for a pipeline agent".
            if unnamed or kept or now - (note.get('seen') or 0) > 60:
                self.store.set_meta('telemetry', {'seen': now, 'unnamed': now if unnamed else note.get('unnamed')})
        return kept

    def _api(self, a, ts):
        session = _text(a.get('session.id'))
        if not session:
            return False
        run = self._run_for(session, a.get('agent.name'), ts)
        if run is None:
            return False
        model = a.get('model')
        self.store.api_add({
            'run': run['id'], 'ts': ts, 'model': str(model) if model else None,
            'input': _int(a.get('input_tokens')), 'output': _int(a.get('output_tokens')),
            'cache_read': _int(a.get('cache_read_tokens')), 'cache_creation': _int(a.get('cache_creation_tokens')),
            'cost': _float(a.get('cost_usd')), 'ms': _float(a.get('duration_ms')),
        })
        if model and not run.get('model'):
            self.store.run_set(run['id'], model=str(model))
        return True

    def _run_for(self, session, agent_name, ts):
        """The run a model reply belongs to. Hooks open runs; a reply only ever joins one.

        A reply that names no agent is the session's own (`claude --agent adlc:builder`). One that names a pipeline
        agent joins that agent's run in the session. Any other name is not ours: that includes 'custom', which is
        what Claude Code calls a plugin agent unless OTEL_LOG_TOOL_DETAILS=1 is set.
        """
        runs = self.store.runs_of_session(session)
        if not agent_name:
            main = [r for r in runs if not r.get('agent_id')]
            return main[-1] if main else None
        station = pipeline.station_for(agent_name)
        match = [r for r in runs if r['station'] == station] if station else []
        fit = [r for r in match if r['started'] - 5 <= ts and (not r.get('ended') or ts <= r['ended'] + 30)]
        return (fit or match or [None])[-1]


def _dicts(items):
    return [i for i in items if isinstance(i, dict)] if isinstance(items, list) else []


def _attrs(items):
    return {i.get('key'): _value(i.get('value')) for i in _dicts(items)}


def _value(v):
    if not isinstance(v, dict):
        return v
    for key in ('stringValue', 'intValue', 'doubleValue', 'boolValue'):
        if key in v:
            return v[key]
    return None


def _float(v):
    """A finite number, or 0: 'Infinity' and '1e999' are valid floats and must not reach the page as JSON."""
    try:
        f = float(v)
    except (TypeError, ValueError):
        return 0.0
    return f if math.isfinite(f) else 0.0


def _int(v):
    return int(_float(v))


def _nanos(v):
    n = _float(v)
    return n / 1e9 if n > 0 else None


def data_home():
    """Where the database and the server's marker file live. The hook script reads the same variable."""
    return os.environ.get('ADLC_MC_HOME') or os.path.join(os.path.expanduser('~'), '.adlc', 'mission-control')
