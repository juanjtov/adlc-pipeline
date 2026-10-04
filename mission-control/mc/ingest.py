"""Turns what Claude Code sends into rows: hook events become runs and steps, telemetry becomes model replies.

Only agent runs that map to a pipeline station are kept. Anything else is dropped on arrival.
"""
import os
import subprocess
import time

from . import pipeline


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


def parse_remote(url):
    """'git@github.com:owner/name.git' or 'https://github.com/owner/name' -> 'owner/name'."""
    url = (url or '').strip()
    if not url:
        return None
    if url.endswith('.git'):
        url = url[:-4]
    tail = url.split('github.com')[-1].lstrip(':/')
    parts = [p for p in tail.split('/') if p]
    return '/'.join(parts[-2:]) if len(parts) >= 2 else None


class Ingest:
    def __init__(self, store, repos=None, on_repo=None):
        self.store = store
        self.repos = repos or Repos()
        self.on_repo = on_repo or (lambda repo: None)
        self.pending = {}   # (session, station) -> task prompt handed to a subagent that has not started yet

    # ------------------------------------------------------------------ hooks
    def hook(self, ev, now=None):
        """One hook input from Claude Code. Returns True when it changed what the screen shows."""
        now = now or time.time()
        name = ev.get('hook_event_name') or ''
        session = ev.get('session_id') or ''
        if not session:
            return False
        station = pipeline.station_for(ev.get('agent_type'))
        tool = ev.get('tool_name') or ''
        tool_input = ev.get('tool_input') if isinstance(ev.get('tool_input'), dict) else {}

        # A parent session handing work to a pipeline agent: keep the prompt for when that agent starts.
        if name == 'PreToolUse' and tool in ('Task', 'Agent'):
            child = pipeline.station_for(tool_input.get('subagent_type'))
            if child:
                self.pending[(session, child)] = tool_input.get('prompt') or ''
        if not station:
            if name == 'SessionEnd':
                return self._end_session(session, now)
            return False

        run_id = session + (':' + str(ev['agent_id']) if ev.get('agent_id') else '')
        cwd = ev.get('cwd') or ''
        fields = {'session': session, 'agent_id': ev.get('agent_id'), 'agent_type': ev.get('agent_type'), 'station': station,
                  'cwd': cwd, 'transcript': ev.get('agent_transcript_path') or ev.get('transcript_path')}
        if self.store.run(run_id) is None:
            repo, branch = self.repos.lookup(cwd)
            fields.update({'repo': repo, 'branch': branch, 'issue': pipeline.issue_in_branch(branch)})
            prompt = self.pending.pop((session, station), None)
            if prompt:
                fields.update(self._prompt_fields(prompt))
            if repo:
                self.on_repo(repo)
        self.store.run_touch(run_id, now, **fields)
        run = self.store.run(run_id)
        if run.get('ended') and name not in ('Stop', 'SubagentStop', 'SessionEnd'):
            self.store.run_set(run_id, ended=None)   # a new turn in the same session: the run is live again

        if name == 'UserPromptSubmit':
            prompt = ev.get('prompt') or ''
            if prompt and not run.get('prompt'):
                self.store.run_set(run_id, **self._prompt_fields(prompt))
        elif name == 'PreToolUse':
            kind, label = pipeline.step_label(tool, tool_input, cwd)
            path = tool_input.get('file_path') if tool in ('Edit', 'Write', 'MultiEdit', 'NotebookEdit') else None
            self.store.step_open(run_id, ev.get('tool_use_id'), tool, kind, label, path, now, tool_input)
        elif name in ('PostToolUse', 'PostToolUseFailure'):
            ok = name == 'PostToolUse'
            output = ev.get('tool_response') if ok else (ev.get('error') or ev.get('tool_response'))
            if not self.store.step_close(run_id, ev.get('tool_use_id'), tool, now, ok, output):
                kind, label = pipeline.step_label(tool, tool_input, cwd)
                self.store.step_open(run_id, ev.get('tool_use_id'), tool, kind, label, None, now, tool_input)
                self.store.step_close(run_id, ev.get('tool_use_id'), tool, now, ok, output)
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

    def _prompt_fields(self, prompt):
        issue, pr = pipeline.refs_in(prompt)
        out = {'prompt': prompt}
        if issue is not None:
            out['issue'] = issue
        if pr is not None:
            out['pr'] = pr
        return out

    def _end_session(self, session, now):
        changed = False
        for run in self.store.runs_of_session(session):
            if not run.get('ended'):
                self.store.run_set(run['id'], ended=now)
                changed = True
        return changed

    # ------------------------------------------------------------------ telemetry
    def otlp_logs(self, doc, now=None):
        """An OTLP/HTTP JSON logs export. Keeps the api_request events. Returns how many were stored."""
        now = now or time.time()
        kept = 0
        for rl in doc.get('resourceLogs') or []:
            base = _attrs((rl.get('resource') or {}).get('attributes'))
            for sl in rl.get('scopeLogs') or []:
                for rec in sl.get('logRecords') or []:
                    attrs = dict(base)
                    attrs.update(_attrs(rec.get('attributes')))
                    event = str(attrs.get('event.name') or _value(rec.get('body')) or '')
                    if not event.endswith('api_request'):
                        continue
                    ts = _nanos(rec.get('timeUnixNano') or rec.get('observedTimeUnixNano')) or now
                    kept += 1 if self._api(attrs, ts) else 0
        return kept

    def _api(self, a, ts):
        session = str(a.get('session.id') or '')
        if not session:
            return False
        run = self._run_for(session, a.get('agent.name'), ts)
        if run is None:
            return False
        model = a.get('model')
        self.store.api_add({
            'run': run['id'], 'session': session, 'agent': a.get('agent.name'), 'ts': ts, 'model': model,
            'input': _int(a.get('input_tokens')), 'output': _int(a.get('output_tokens')),
            'cache_read': _int(a.get('cache_read_tokens')), 'cache_creation': _int(a.get('cache_creation_tokens')),
            'cost': _float(a.get('cost_usd')), 'ms': _float(a.get('duration_ms')),
        })
        if model and not run.get('model'):
            self.store.run_set(run['id'], model=str(model))
        return True

    def _run_for(self, session, agent_name, ts):
        """The run a model reply belongs to: same session, and the same agent when the reply names one."""
        runs = self.store.runs_of_session(session)
        station = pipeline.station_for(agent_name)
        if station:
            match = [r for r in runs if r['station'] == station]
            if match:
                return match[-1]
            # Telemetry can arrive before the first hook does: open the run from what the reply tells us.
            run_id = session
            self.store.run_touch(run_id, ts, session=session, agent_type=str(agent_name), station=station)
            return self.store.run(run_id)
        if agent_name:
            return None   # a named agent that is not part of the pipeline
        main = [r for r in runs if not r.get('agent_id')]
        return main[-1] if main else None


def _attrs(items):
    return {i.get('key'): _value(i.get('value')) for i in (items or []) if isinstance(i, dict)}


def _value(v):
    if not isinstance(v, dict):
        return v
    for key in ('stringValue', 'intValue', 'doubleValue', 'boolValue'):
        if key in v:
            return v[key]
    return None


def _int(v):
    try:
        return int(float(v))
    except (TypeError, ValueError):
        return 0


def _float(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return 0.0


def _nanos(v):
    try:
        n = int(v)
    except (TypeError, ValueError):
        return None
    return n / 1e9 if n > 0 else None


def data_home():
    return os.environ.get('ADLC_MC_HOME') or os.path.join(os.path.expanduser('~'), '.adlc', 'mission-control')
