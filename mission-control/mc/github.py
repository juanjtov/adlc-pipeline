"""Reads the pipeline's state from GitHub with the user's own `gh` login. Read-only: one GraphQL call per poll."""
import calendar
import json
import re
import subprocess
import threading
import time

from . import pipeline

QUERY = """
query($owner: String!, $name: String!) {
  repository(owner: $owner, name: $name) {
    open: issues(first: 60, states: OPEN, orderBy: {field: UPDATED_AT, direction: DESC}) { nodes { ...issue } }
    closed: issues(first: 25, states: CLOSED, orderBy: {field: UPDATED_AT, direction: DESC}) { nodes { ...issue } }
    pullRequests(first: 40, orderBy: {field: UPDATED_AT, direction: DESC}) {
      nodes {
        number title url state createdAt mergedAt updatedAt headRefName body
        author { login }
        labels(first: 20) { nodes { name } }
        closingIssuesReferences(first: 5) { nodes { number repository { nameWithOwner } } }
        commits(last: 40) { nodes { commit { messageHeadline committedDate } } }
        comments(last: 40) { nodes { id body createdAt author { login } } }
      }
    }
  }
}
fragment issue on Issue {
  number title url state createdAt closedAt updatedAt
  author { login }
  milestone { title }
  labels(first: 20) { nodes { name } }
  timelineItems(last: 60, itemTypes: [LABELED_EVENT, UNLABELED_EVENT]) {
    nodes {
      __typename
      ... on LabeledEvent { createdAt label { name } actor { login } }
      ... on UnlabeledEvent { createdAt label { name } actor { login } }
    }
  }
  comments(last: 30) { nodes { id body createdAt author { login } } }
}
"""


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
    cmd = ['gh', 'api', 'graphql', '-f', 'query=' + QUERY, '-F', 'owner=' + owner, '-F', 'name=' + name]
    try:
        out = run(cmd, capture_output=True, text=True, timeout=30)
    except FileNotFoundError:
        raise GhError('The gh command is not installed')
    except subprocess.SubprocessError as exc:
        raise GhError('gh did not answer: ' + type(exc).__name__)
    if out.returncode != 0:
        err = (out.stderr or out.stdout or '').strip().splitlines()
        msg = err[0] if err else 'gh failed'
        if 'auth' in msg.lower() or 'login' in msg.lower():
            msg = 'gh is not signed in. Run: gh auth login'
        raise GhError(msg[:160])
    try:
        doc = json.loads(out.stdout)
    except ValueError:
        raise GhError('gh returned something that is not JSON')
    data = (doc.get('data') or {}).get('repository')
    if not data:
        errs = doc.get('errors') or [{}]
        raise GhError(str(errs[0].get('message') or 'Repository not found')[:160])
    return data


def apply(store, repo, data):
    """Mirror one fetch into the store."""
    for node in ((data.get('open') or {}).get('nodes') or []) + ((data.get('closed') or {}).get('nodes') or []):
        number = node['number']
        store.put('issues', {
            'repo': repo, 'number': number, 'title': node.get('title') or '', 'url': node.get('url') or '',
            'state': node.get('state') or 'OPEN', 'labels': json.dumps([l['name'] for l in _nodes(node, 'labels')]),
            'milestone': (node.get('milestone') or {}).get('title'), 'author': (node.get('author') or {}).get('login'),
            'created': epoch(node.get('createdAt')), 'closed': epoch(node.get('closedAt')), 'updated': epoch(node.get('updatedAt')),
        })
        for ev in _nodes(node, 'timelineItems'):
            label = (ev.get('label') or {}).get('name')
            if label:
                store.put('label_events', {'repo': repo, 'number': number, 'label': label, 'added': 1 if ev.get('__typename') == 'LabeledEvent' else 0,
                                           'ts': epoch(ev.get('createdAt')), 'actor': (ev.get('actor') or {}).get('login')})
        _comments(store, repo, 'issue', number, node)
    for node in _nodes(data, 'pullRequests'):
        number = node['number']
        # The same order the lanes use: a closing reference in this repo, else the issue the branch names, else the first #N in the body.
        closing = [n['number'] for n in _nodes(node, 'closingIssuesReferences')
                   if ((n.get('repository') or {}).get('nameWithOwner') or repo).lower() == repo.lower()]
        issue = closing[0] if closing else pipeline.issue_in_branch(node.get('headRefName')) or _first_ref(node.get('body'))
        commits = [c.get('commit') or {} for c in _nodes(node, 'commits')]
        dates = [epoch(c.get('committedDate')) for c in commits if c.get('committedDate')]
        fixes = sorted(epoch(c.get('committedDate')) for c in commits if (c.get('messageHeadline') or '').startswith('adlc-fix:') and c.get('committedDate'))
        store.put('prs', {
            'repo': repo, 'number': number, 'title': node.get('title') or '', 'url': node.get('url') or '', 'state': node.get('state') or 'OPEN',
            'head': node.get('headRefName'), 'labels': json.dumps([l['name'] for l in _nodes(node, 'labels')]), 'issue': issue,
            'author': (node.get('author') or {}).get('login'), 'created': epoch(node.get('createdAt')), 'merged': epoch(node.get('mergedAt')),
            'updated': epoch(node.get('updatedAt')), 'fix_commits': json.dumps(fixes), 'last_commit': max(dates) if dates else None,
        })
        _comments(store, repo, 'pr', number, node)


def _nodes(node, key):
    return ((node or {}).get(key) or {}).get('nodes') or []


def _comments(store, repo, kind, number, node):
    for c in _nodes(node, 'comments'):
        store.put('comments', {'repo': repo, 'cid': c.get('id'), 'kind': kind, 'number': number, 'ts': epoch(c.get('createdAt')),
                               'author': (c.get('author') or {}).get('login'), 'body': c.get('body') or ''})


def _first_ref(text):
    m = re.search(r'#(\d+)', text or '')
    return int(m.group(1)) if m else None


class Poller(threading.Thread):
    """Polls each known repo in turn and reports whether GitHub could be read."""

    def __init__(self, store, repos, on_change, interval=15.0, fetcher=fetch):
        super().__init__(daemon=True)
        self.store, self.repos, self.on_change, self.interval, self.fetcher = store, repos, on_change, interval, fetcher
        self.status = {}
        self.wake = threading.Event()
        self.stopped = False

    def poll(self, repo):
        try:
            apply(self.store, repo, self.fetcher(repo))
            self.status[repo] = {'ok': True, 'msg': '', 'polled': time.time()}
        except GhError as exc:
            prev = self.status.get(repo) or {}
            self.status[repo] = {'ok': False, 'msg': str(exc), 'polled': prev.get('polled')}
        self.on_change()

    def run(self):
        while not self.stopped:
            for repo in list(self.repos()):
                self.poll(repo)
            self.wake.wait(self.interval)
            self.wake.clear()
