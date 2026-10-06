"""SQLite storage for Mission Control. One file, one lock, standard library only."""
import json
import sqlite3
import threading
from contextlib import contextmanager

# Bump when a table changes shape. A file written by another version is emptied and rebuilt: no released
# version has data to carry over yet. The first release that does must migrate instead.
VERSION = 2
TABLES = ('runs', 'steps', 'api', 'issues', 'label_events', 'prs', 'comments', 'meta')

SCHEMA = """
CREATE TABLE IF NOT EXISTS runs (
  id TEXT PRIMARY KEY, session TEXT, agent_id TEXT, agent_type TEXT, station TEXT, repo TEXT, cwd TEXT,
  branch TEXT, issue INTEGER, pr INTEGER, model TEXT, prompt TEXT, report TEXT,
  started REAL, ended REAL, last_seen REAL);
CREATE INDEX IF NOT EXISTS runs_repo ON runs(repo, started);
CREATE TABLE IF NOT EXISTS steps (
  id INTEGER PRIMARY KEY AUTOINCREMENT, run TEXT, tool_use_id TEXT, tool TEXT, kind TEXT, label TEXT,
  path TEXT, skill TEXT, started REAL, ended REAL, ok INTEGER);
CREATE INDEX IF NOT EXISTS steps_run ON steps(run, id);
CREATE TABLE IF NOT EXISTS api (
  id INTEGER PRIMARY KEY AUTOINCREMENT, run TEXT, ts REAL, model TEXT,
  input INTEGER, output INTEGER, cache_read INTEGER, cache_creation INTEGER, cost REAL, ms REAL);
CREATE INDEX IF NOT EXISTS api_run ON api(run, id);
CREATE TABLE IF NOT EXISTS issues (
  repo TEXT, number INTEGER, title TEXT, url TEXT, state TEXT, labels TEXT, milestone TEXT,
  created REAL, updated REAL, PRIMARY KEY (repo, number));
CREATE TABLE IF NOT EXISTS label_events (
  repo TEXT, number INTEGER, label TEXT, added INTEGER, ts REAL, actor TEXT,
  PRIMARY KEY (repo, number, label, added, ts));
CREATE TABLE IF NOT EXISTS prs (
  repo TEXT, number INTEGER, title TEXT, url TEXT, state TEXT, head TEXT, labels TEXT, issue INTEGER,
  created REAL, merged REAL, fix_commits TEXT, PRIMARY KEY (repo, number));
CREATE TABLE IF NOT EXISTS comments (
  repo TEXT, cid TEXT, kind TEXT, number INTEGER, ts REAL, body TEXT,
  PRIMARY KEY (repo, cid));
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
"""

TEXT_LIMIT = 6000


def clip(value, limit=TEXT_LIMIT):
    """Text for storage, cut to a sane size."""
    if value is None:
        return None
    value = value if isinstance(value, str) else str(value)
    return value if len(value) <= limit else value[:limit] + '…'


class Store:
    def __init__(self, path=':memory:'):
        self.lock = threading.RLock()
        self.depth = 0
        self.db = sqlite3.connect(path, check_same_thread=False)
        self.db.row_factory = sqlite3.Row
        with self.lock:
            if self.db.execute('PRAGMA user_version').fetchone()[0] != VERSION:
                self.db.executescript(''.join('DROP TABLE IF EXISTS %s;' % t for t in TABLES) + 'PRAGMA user_version = %d;' % VERSION)
            self.db.executescript(SCHEMA)
            self.db.commit()

    # ---- small helpers
    def q(self, sql, args=()):
        with self.lock:
            return [dict(r) for r in self.db.execute(sql, args).fetchall()]

    def one(self, sql, args=()):
        rows = self.q(sql, args)
        return rows[0] if rows else None

    def x(self, sql, args=()):
        with self.lock:
            cur = self.db.execute(sql, args)
            if not self.depth:
                self.db.commit()
            return cur

    @contextmanager
    def tx(self):
        """Several writes as one transaction: all of them land, or none does."""
        with self.lock:
            self.depth += 1
            try:
                yield
            except BaseException:
                if self.depth == 1:
                    self.db.rollback()
                raise
            else:
                if self.depth == 1:
                    self.db.commit()
            finally:
                self.depth -= 1

    def put(self, table, row):
        cols = list(row)
        sql = 'INSERT OR REPLACE INTO %s (%s) VALUES (%s)' % (table, ', '.join(cols), ', '.join('?' for _ in cols))
        self.x(sql, [row[c] for c in cols])

    # ---- meta
    def meta(self, key, default=None):
        row = self.one('SELECT value FROM meta WHERE key = ?', (key,))
        return json.loads(row['value']) if row else default

    def set_meta(self, key, value):
        self.x('INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)', (key, json.dumps(value)))

    def repos(self):
        return self.meta('repos', [])

    def add_repo(self, repo):
        with self.lock:
            repos = self.repos()
            if repo and repo not in repos:
                repos.append(repo)
                self.set_meta('repos', repos)
            return repos

    # ---- runs (one per agent session or subagent)
    def run(self, run_id):
        return self.one('SELECT * FROM runs WHERE id = ?', (run_id,))

    def run_touch(self, run_id, ts, **fields):
        """Create the run if new, fill in any fields that are still empty, and mark it seen."""
        with self.lock:
            row = self.run(run_id)
            if row is None:
                base = {'id': run_id, 'started': ts, 'last_seen': ts}
                base.update({k: v for k, v in fields.items() if v is not None})
                self.put('runs', base)
                return True
            updates = {k: v for k, v in fields.items() if v is not None and row.get(k) in (None, '')}
            updates['last_seen'] = ts
            sets = ', '.join(k + ' = ?' for k in updates)
            self.x('UPDATE runs SET %s WHERE id = ?' % sets, list(updates.values()) + [run_id])
            return False

    def run_set(self, run_id, **fields):
        sets = ', '.join(k + ' = ?' for k in fields)
        self.x('UPDATE runs SET %s WHERE id = ?' % sets, list(fields.values()) + [run_id])

    def runs_of_session(self, session):
        return self.q('SELECT * FROM runs WHERE session = ? ORDER BY started', (session,))

    def runs_in(self, repo, since):
        return self.q('SELECT * FROM runs WHERE repo = ? AND started >= ? ORDER BY started', (repo, since))

    # ---- steps (one per tool call)
    def step_open(self, run_id, tool_use_id, tool, kind, label, path, skill, ts):
        self.x('INSERT INTO steps (run, tool_use_id, tool, kind, label, path, skill, started) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
               (run_id, tool_use_id, tool, kind, clip(label), path, skill, ts))

    def step_close(self, run_id, tool_use_id, tool, ts, ok):
        with self.lock:
            row = None
            if tool_use_id:
                row = self.one('SELECT id FROM steps WHERE run = ? AND tool_use_id = ? AND ended IS NULL ORDER BY id DESC LIMIT 1', (run_id, tool_use_id))
            if row is None:
                row = self.one('SELECT id FROM steps WHERE run = ? AND tool = ? AND ended IS NULL ORDER BY id DESC LIMIT 1', (run_id, tool))
            if row is None:
                return False
            self.x('UPDATE steps SET ended = ?, ok = ? WHERE id = ?', (ts, 1 if ok else 0, row['id']))
            return True

    def steps_end_stale(self, run_id):
        """A call that was denied or interrupted never reports back. Once a later call has finished, end it as not done."""
        with self.lock:
            last = self.one('SELECT MAX(ended) AS t FROM steps WHERE run = ?', (run_id,))['t']
            if last:
                self.x('UPDATE steps SET ended = ?, ok = 0 WHERE run = ? AND ended IS NULL AND started < ?', (last, run_id, last))

    def steps(self, run_id, limit=80):
        rows = self.q('SELECT * FROM steps WHERE run = ? ORDER BY id DESC LIMIT ?', (run_id, limit))
        return list(reversed(rows))

    def step_count(self, run_id):
        return self.one('SELECT COUNT(*) AS n FROM steps WHERE run = ?', (run_id,))['n']

    def step_values(self, run_id, column):
        """Every distinct file path ('path') or skill ('skill') a run's steps name, in first-use order."""
        assert column in ('path', 'skill')
        return [r[column] for r in self.q('SELECT %s FROM steps WHERE run = ? AND %s IS NOT NULL GROUP BY %s ORDER BY MIN(id)' % (column, column, column), (run_id,))]

    def runs_with_open_step(self):
        return {r['run'] for r in self.q('SELECT DISTINCT run FROM steps WHERE ended IS NULL')}

    # ---- model replies (one per API request, from telemetry)
    def api_add(self, row):
        self.put('api', row)

    def api_rows(self, run_id, limit=60):
        rows = self.q('SELECT * FROM api WHERE run = ? ORDER BY id DESC LIMIT ?', (run_id, limit))
        return list(reversed(rows))

    def api_sum(self, run_ids, t0=None, t1=None):
        """Token and cost totals over a set of runs, optionally inside a time window."""
        out = {'tok': 0, 'usd': 0.0, 'input': 0, 'cacheRead': 0, 'cacheCreation': 0, 'output': 0, 'replies': 0, 'ms': 0.0}
        if not run_ids:
            return out
        marks = ', '.join('?' for _ in run_ids)
        sql = ('SELECT COUNT(*) AS n, COALESCE(SUM(input), 0) AS i, COALESCE(SUM(output), 0) AS o, COALESCE(SUM(cache_read), 0) AS cr, '
               'COALESCE(SUM(cache_creation), 0) AS cc, COALESCE(SUM(cost), 0) AS usd, COALESCE(SUM(ms), 0) AS ms FROM api WHERE run IN (%s)' % marks)
        args = list(run_ids)
        if t0 is not None:
            sql += ' AND ts >= ?'
            args.append(t0)
        if t1 is not None:
            sql += ' AND ts < ?'
            args.append(t1)
        r = self.one(sql, args)
        out.update({'tok': r['i'] + r['o'] + r['cr'] + r['cc'], 'usd': r['usd'], 'input': r['i'], 'cacheRead': r['cr'],
                    'cacheCreation': r['cc'], 'output': r['o'], 'replies': r['n'], 'ms': r['ms']})
        return out

    # ---- GitHub mirror
    def issues(self, repo):
        rows = self.q('SELECT * FROM issues WHERE repo = ?', (repo,))
        for r in rows:
            r['labels'] = json.loads(r['labels'] or '[]')
        return rows

    def prs(self, repo):
        rows = self.q('SELECT * FROM prs WHERE repo = ?', (repo,))
        for r in rows:
            r['labels'] = json.loads(r['labels'] or '[]')
            r['fix_commits'] = json.loads(r['fix_commits'] or '[]')
        return rows

    def label_events(self, repo):
        return self.q('SELECT * FROM label_events WHERE repo = ? ORDER BY ts', (repo,))

    def comments(self, repo):
        return self.q('SELECT * FROM comments WHERE repo = ? ORDER BY ts', (repo,))
