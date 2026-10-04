"""Reads the pipeline's state from GitHub with the user's own `gh` login. Read-only: one GraphQL call per poll."""
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


def fetch(repo, run=subprocess.run):
    """One read of a repo's issues, pull requests, labels and comments. Raises GhError with a plain reason."""
    owner, _, name = repo.partition('/')
    # -f, not -F: -F would read a repo named '2048' as a number.
    cmd = ['gh', 'api', 'graphql', '-f', 'query=' + QUERY, '-f', 'owner=' + owner, '-f', 'name=' + name]
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
        doc = json.loads(out.stdout)
    except ValueError:
        raise GhError('gh returned something that is not JSON')
    data = (doc.get('data') or {}).get('repository') if isinstance(doc, dict) else None
    if not data:
        errs = (doc.get('errors') if isinstance(doc, dict) else None) or [{}]
        raise GhError(str(errs[0].get('message') or 'Repository not found')[:160])
    return data


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

    def __init__(self, store, repos, on_change, interval=15.0, fetcher=fetch):
        super().__init__(daemon=True)
        self.store, self.repos, self.on_change, self.interval, self.fetcher = store, repos, on_change, interval, fetcher
        self.status = {}
        self.seen = {}   # repo -> digest of the last read, so an unchanged read costs no writes
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
            self.status[repo] = {'ok': True, 'msg': '', 'polled': time.time()}
        except GhError as exc:
            self.status[repo] = {'ok': False, 'msg': str(exc), 'polled': last}
        except Exception as exc:   # whatever a read runs into, this thread goes on: a dead poller would leave the page saying GitHub is followed
            self.status[repo] = {'ok': False, 'msg': 'Reading GitHub failed (%s)' % type(exc).__name__, 'polled': last}
        self.on_change()

    def run(self):
        while not self.stopped:
            watched = list(self.repos())
            for repo in watched:
                self.poll(repo)
            self.wake.wait(self.interval if watched else None)   # no page open: wait for one
            self.wake.clear()
