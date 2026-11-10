"""Reads the pipeline's state from GitHub with the user's own `gh` login. Read-only: one GraphQL call per poll,
plus, now and then, one REST call that asks whether GitHub is still running the repo's workflows at all."""
import calendar
import hashlib
import json
import subprocess
import threading
import time

from . import pipeline

# Open issues are asked for by pipeline label (GitHub matches any of the labels), so a request that has waited
# at a gate for a week is still returned. Closed issues and closed pull requests only matter while they are recent.
QUERY = """
query($owner: String!, $name: String!) {
  repository(owner: $owner, name: $name) {
    open: issues(first: 60, states: OPEN, labels: %s, orderBy: {field: UPDATED_AT, direction: DESC}) { nodes { ...issue } }
    closed: issues(first: 25, states: CLOSED, orderBy: {field: UPDATED_AT, direction: DESC}) { nodes { ...issue } }
    openPrs: pullRequests(first: 40, states: OPEN, orderBy: {field: UPDATED_AT, direction: DESC}) { nodes { ...pr } }
    closedPrs: pullRequests(first: 15, states: [MERGED, CLOSED], orderBy: {field: UPDATED_AT, direction: DESC}) { nodes { ...pr } }
  }
}
fragment issue on Issue {
  number title url state createdAt updatedAt
  milestone { title }
  labels(first: 20) { nodes { name } }
  timelineItems(last: 60, itemTypes: [LABELED_EVENT, UNLABELED_EVENT]) {
    nodes {
      __typename
      ... on LabeledEvent { createdAt label { name } actor { login } }
      ... on UnlabeledEvent { createdAt label { name } actor { login } }
    }
  }
  comments(last: 30) { nodes { id body createdAt } }
}
fragment pr on PullRequest {
  number title url state createdAt mergedAt headRefName
  labels(first: 20) { nodes { name } }
  closingIssuesReferences(first: 5) { nodes { number repository { nameWithOwner } } }
  timelineItems(last: 40, itemTypes: [LABELED_EVENT]) { nodes { ... on LabeledEvent { createdAt label { name } actor { login } } } }
  commits(last: 40) { nodes { commit { messageHeadline committedDate } } }
  comments(last: 40) { nodes { id body createdAt } }
}
""" % json.dumps(list(pipeline.LABEL_SLOT))


class GhError(Exception):
    pass


def epoch(iso):
    """'2026-10-03T20:12:48Z' -> seconds since the epoch. None stays None."""
    if not iso:
        return None
    return float(calendar.timegm(time.strptime(iso[:19], '%Y-%m-%dT%H:%M:%S')))


def _gh(cmd, run):
    """Runs one gh command and returns its JSON. Raises GhError with a plain reason."""
    try:
        out = run(cmd, capture_output=True, text=True, timeout=30)
    except FileNotFoundError:
        raise GhError('The gh command is not installed')
    except (OSError, subprocess.SubprocessError) as exc:
        raise GhError('gh did not answer: ' + type(exc).__name__)
    if out.returncode != 0:
        err = (out.stderr or out.stdout or '').strip().splitlines()
        msg = err[0] if err else 'gh failed'
        if any(sign in msg.lower() for sign in ('gh auth login', 'not logged in', 'bad credentials', 'http 401')):
            msg = 'gh is not signed in. Run: gh auth login'
        raise GhError(msg[:160])
    try:
        return json.loads(out.stdout)
    except ValueError:
        raise GhError('gh returned something that is not JSON')


def fetch(repo, run=subprocess.run):
    """One read of a repo's issues, pull requests, labels and comments. Raises GhError with a plain reason."""
    owner, _, name = repo.partition('/')
    # -f, not -F: -F would read a repo named '2048' as a number.
    doc = _gh(['gh', 'api', 'graphql', '-f', 'query=' + QUERY, '-f', 'owner=' + owner, '-f', 'name=' + name], run)
    data = (doc.get('data') or {}).get('repository') if isinstance(doc, dict) else None
    if not data:
        errs = (doc.get('errors') if isinstance(doc, dict) else None) or [{}]
        raise GhError(str(errs[0].get('message') or 'Repository not found')[:160])
    return data


# A run that GitHub refused to start (the account's included Actions minutes or spending limit are used up) still
# appears as a completed run: `failure`, within seconds of its creation, no job step executed. Every workflow goes
# that way at once, the tripwire that watches the default branch included, and nothing on GitHub says so. The last
# few runs are read as blocked when, skipped and cancelled runs left out (a lane whose job-level `if:` did not match
# concludes `skipped` before a runner is asked for, so it says nothing either way), at least this many remain, all
# of them failed within FAST_SECONDS of being created, and the latest ran no step. A test that fails fast runs steps.
# Actions turned off for the repo creates no run at all, so it is not seen here.
BLOCKED_MIN_RUNS = 3
FAST_SECONDS = 60
SAYS_NOTHING = ('skipped', 'cancelled', 'neutral')   # a run with this conclusion never asked for a runner


def actions_health(repo, run=subprocess.run):
    """Whether GitHub is still running this repo's workflows. {'blocked', 'runs', 'latest', 'since'}; raises GhError."""
    doc = _gh(['gh', 'api', 'repos/%s/actions/runs?per_page=10&status=completed' % repo], run)
    runs = [r for r in ((doc.get('workflow_runs') if isinstance(doc, dict) else None) or [])
            if r.get('status') == 'completed' and r.get('conclusion') not in SAYS_NOTHING]
    out = {'blocked': False, 'runs': len(runs), 'latest': runs[0].get('id') if runs else None, 'since': None}
    if len(runs) < BLOCKED_MIN_RUNS:
        return out
    for r in runs:
        t0, t1 = epoch(r.get('created_at')), epoch(r.get('updated_at'))
        if r.get('conclusion') != 'failure' or t0 is None or t1 is None or t1 - t0 > FAST_SECONDS:
            return out
    jobs = _gh(['gh', 'api', 'repos/%s/actions/runs/%s/jobs?per_page=30' % (repo, runs[0].get('id'))], run)
    ran = [s for j in ((jobs.get('jobs') if isinstance(jobs, dict) else None) or [])
           for s in (j.get('steps') or []) if s.get('conclusion') not in (None, 'skipped')]
    if ran:
        return out
    out['blocked'] = True
    out['since'] = runs[-1].get('created_at')   # the oldest of the fast failures read: it started no later than this
    return out


def apply(store, repo, data):
    """Make the mirror of a repo match one fetch. Issues and pull requests are replaced whole, so one that left
    the line (closed, labels removed) leaves the mirror too. Label history and comments only grow."""
    with store.tx():
        store.x('DELETE FROM issues WHERE repo = ?', (repo,))
        store.x('DELETE FROM prs WHERE repo = ?', (repo,))
        for node in _nodes(data, 'open') + _nodes(data, 'closed'):
            number = node['number']
            store.put('issues', {
                'repo': repo, 'number': number, 'title': node.get('title') or '', 'url': node.get('url') or '',
                'state': node.get('state') or 'OPEN', 'labels': json.dumps([l['name'] for l in _nodes(node, 'labels')]),
                'milestone': (node.get('milestone') or {}).get('title'),
                'created': epoch(node.get('createdAt')), 'updated': epoch(node.get('updatedAt')),
            })
            for ev in _nodes(node, 'timelineItems'):
                label = (ev.get('label') or {}).get('name')
                if label:
                    store.put('label_events', {'repo': repo, 'number': number, 'label': label, 'added': 1 if ev.get('__typename') == 'LabeledEvent' else 0,
                                               'ts': epoch(ev.get('createdAt')), 'actor': (ev.get('actor') or {}).get('login')})
            _comments(store, repo, 'issue', number, node)
        for node in _nodes(data, 'openPrs') + _nodes(data, 'closedPrs'):
            number = node['number']
            # The issue a pull request works on, as the diff-scope lane reads it: a closing reference in this repo,
            # else the issue its branch names. A bare #N in the text ties it to nothing.
            closing = [n['number'] for n in _nodes(node, 'closingIssuesReferences')
                       if ((n.get('repository') or {}).get('nameWithOwner') or repo).lower() == repo.lower()]
            issue = closing[0] if closing else pipeline.issue_in_branch(node.get('headRefName'))
            commits = [c.get('commit') or {} for c in _nodes(node, 'commits')]
            fixes = sorted(epoch(c.get('committedDate')) for c in commits if (c.get('messageHeadline') or '').startswith('adlc-fix:') and c.get('committedDate'))
            store.put('prs', {
                'repo': repo, 'number': number, 'title': node.get('title') or '', 'url': node.get('url') or '', 'state': node.get('state') or 'OPEN',
                'head': node.get('headRefName'), 'labels': json.dumps([l['name'] for l in _nodes(node, 'labels')]), 'issue': issue,
                'created': epoch(node.get('createdAt')), 'merged': epoch(node.get('mergedAt')), 'fix_commits': json.dumps(fixes),
            })
            # The times the review lane sent it back (pipeline.fix_rounds counts them), kept with the label history
            # under the pull request's own number: issues and pull requests of a repo share one run of numbers.
            # Only this label: a stage label someone put on a pull request must not read as a request on the line.
            for ev in _nodes(node, 'timelineItems'):
                if (ev.get('label') or {}).get('name') == pipeline.CHANGES_LABEL:
                    store.put('label_events', {'repo': repo, 'number': number, 'label': pipeline.CHANGES_LABEL, 'added': 1,
                                               'ts': epoch(ev.get('createdAt')), 'actor': (ev.get('actor') or {}).get('login')})
            _comments(store, repo, 'pr', number, node)


def _nodes(node, key):
    return [n for n in (((node or {}).get(key) or {}).get('nodes') or []) if n]


def _comments(store, repo, kind, number, node):
    for c in _nodes(node, 'comments'):
        store.put('comments', {'repo': repo, 'cid': c.get('id'), 'kind': kind, 'number': number, 'ts': epoch(c.get('createdAt')), 'body': c.get('body') or ''})


class Poller(threading.Thread):
    """Reads GitHub for the repos a page is open on, and reports whether each could be read.

    `repos` returns those repos. With no page open nothing is read: a read costs a few points of the
    account's hourly GraphQL budget, and nobody is there to see the result.
    """

    # The Actions read is one REST call (two when the runs look blocked) against a separate budget from GraphQL;
    # once every ACTIONS_EVERY polls is about every two minutes at the default interval, and the first poll reads it.
    ACTIONS_EVERY = 8

    def __init__(self, store, repos, on_change, interval=15.0, fetcher=fetch, actions=actions_health):
        super().__init__(daemon=True)
        self.store, self.repos, self.on_change, self.interval, self.fetcher = store, repos, on_change, interval, fetcher
        self.actions_fetcher = actions
        self.status = {}
        self.seen = {}   # repo -> digest of the last read, so an unchanged read costs no writes
        self.actions = {}   # repo -> the last Actions health read; kept when a later read fails
        self.ticks = {}
        self.wake = threading.Event()
        self.stopped = False

    def poll(self, repo):
        last = (self.status.get(repo) or {}).get('polled')
        try:
            data = self.fetcher(repo)
            digest = hashlib.sha1(json.dumps(data, sort_keys=True).encode()).hexdigest()
            if digest != self.seen.get(repo):
                apply(self.store, repo, data)
                self.seen[repo] = digest
            self.status[repo] = {'ok': True, 'msg': '', 'polled': time.time(), 'actions': self._actions(repo)}
        except GhError as exc:
            self.status[repo] = {'ok': False, 'msg': str(exc), 'polled': last, 'actions': self.actions.get(repo)}
        except Exception as exc:   # whatever a read runs into, this thread goes on: a dead poller would leave the page saying GitHub is followed
            self.status[repo] = {'ok': False, 'msg': 'Reading GitHub failed (%s)' % type(exc).__name__, 'polled': last, 'actions': self.actions.get(repo)}
        self.on_change()

    def _actions(self, repo):
        """The Actions health, read every ACTIONS_EVERY polls. A failed read keeps the last answer: it never flips the
        page's word, and it never makes the GitHub read itself count as failed."""
        tick = self.ticks.get(repo, 0)
        self.ticks[repo] = tick + 1
        if tick % self.ACTIONS_EVERY == 0:
            try:
                self.actions[repo] = self.actions_fetcher(repo)
            except Exception:
                pass
        return self.actions.get(repo)

    def run(self):
        while not self.stopped:
            watched = list(self.repos())
            for repo in watched:
                self.poll(repo)
            self.wake.wait(self.interval if watched else None)   # no page open: wait for one
            self.wake.clear()
