#!/usr/bin/env python3
"""ADLC Mission Control: a local, read-only live view of the pipeline.

Standard library only (Python 3.9+). It listens on 127.0.0.1, receives what Claude Code sends
(hook events and telemetry), reads GitHub through `gh`, and serves one page that shows it all.
"""
import argparse
import atexit
import json
import mimetypes
import os
import signal
import sys
import threading
import time
import traceback
import urllib.request
import webbrowser
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from mc import github, ingest, pipeline, state  # noqa: E402
from mc.store import Store  # noqa: E402

WEB = os.path.join(HERE, 'web')
PLUGIN_ROOT = os.path.dirname(HERE)
DEFAULT_PORT = 4319
MAX_BODY = 8 * 1024 * 1024
MAX_INFLATED = 4 * MAX_BODY


class App:
    """Everything the request handlers share."""

    def __init__(self, store, repo, demo=False, poll=True, interval=15.0):
        self.store, self.demo = store, demo
        self.default_repo = (repo or '').lower()
        self.port = DEFAULT_PORT
        self.changed = threading.Condition()
        self.version = 0
        self.watching = {}   # repo -> pages open on it. GitHub is read only for these.
        self.agents = {st: pipeline.read_agent(PLUGIN_ROOT, st) for st in pipeline.STATIONS}
        if any(a['guard'] == 'missing' for a in self.agents.values()):
            print("Mission Control: the plugin's guard hook (hooks/adlc_guard.py) could not be read. The Permissions panel "
                  "shows each agent file's tools line as written and says the Bash limits are unknown.", file=sys.stderr)
        self.ingest = ingest.Ingest(store, on_repo=store.add_repo)
        if self.default_repo:
            store.add_repo(self.default_repo)
        self.poller = github.Poller(store, self.watched, self.bump, interval=interval)
        if poll and not demo:
            self.poller.start()

    def watched(self):
        with self.changed:
            return [repo for repo, pages in self.watching.items() if repo and pages > 0]

    def watch(self, repo, delta):
        with self.changed:
            self.watching[repo] = self.watching.get(repo, 0) + delta
        if delta > 0:
            self.poller.wake.set()   # a page just opened: read GitHub now, not at the next tick

    def bump(self):
        with self.changed:
            self.version += 1
            self.changed.notify_all()

    def repo(self, wanted=None):
        wanted, repos = (wanted or '').lower(), self.store.repos()
        if wanted in repos:
            return wanted
        return self.default_repo or (repos[0] if repos else '')

    def state(self, wanted=None):
        repo = self.repo(wanted)
        mode = 'demo' if self.demo else 'live'
        return state.build(self.store, repo, agents=self.agents, github=self.poller.status.get(repo), mode=mode, plugin_root=PLUGIN_ROOT)

    def meta(self):
        return {'stations': [self.agents[st] for st in pipeline.STATIONS], 'demo': self.demo, 'port': self.port}


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    server_version = 'adlc-mission-control'
    app = None

    def log_message(self, fmt, *args):   # quiet: one line per request is noise for a local tool
        pass

    def _allowed(self, api):
        """This server is for this machine and for its own page. Claude Code and curl send no Origin and no
        Sec-Fetch-Site; a page on another site sends both, and is refused."""
        host = (self.headers.get('Host') or '').split(':')[0]
        if host not in ('localhost', '127.0.0.1'):
            self._send(403, {'error': 'Mission Control only answers on localhost'})
            return False
        origin = self.headers.get('Origin')
        elsewhere = origin and urlparse(origin).netloc != self.headers.get('Host')
        if elsewhere or (api and self.headers.get('Sec-Fetch-Site') not in (None, 'same-origin', 'none')):
            self._send(403, {'error': 'Requests from other sites are not accepted'})
            return False
        return True

    def _send(self, code, body, ctype='application/json'):
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(code)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Cache-Control', 'no-store')
        if code >= 400:
            self.send_header('Connection', 'close')   # the request body may be unread; it must not be taken for the next request
        self.end_headers()
        self.wfile.write(data)

    def _json(self):
        """The request body as a JSON object. None after the refusal has been sent."""
        try:
            length = int(self.headers.get('Content-Length') or 0)
        except ValueError:
            length = 0
        if length <= 0 or length > MAX_BODY:
            self._send(413 if length > MAX_BODY else 400, {'error': 'Send a JSON body of at most %d MB' % (MAX_BODY >> 20)})
            return None
        raw = self.rfile.read(length)
        try:
            if (self.headers.get('Content-Encoding') or '').lower() == 'gzip':
                inflate = zlib.decompressobj(31)
                raw = inflate.decompress(raw, MAX_INFLATED)
                if inflate.unconsumed_tail:
                    self._send(413, {'error': 'The body is too large'})
                    return None
            doc = json.loads(raw.decode('utf-8'))
        except (ValueError, zlib.error, RecursionError):   # ValueError covers bad JSON and bad UTF-8
            doc = None
        if not isinstance(doc, dict):
            self._send(400, {'error': 'The body is not a JSON object'})
            return None
        return doc

    # ---- GET
    def do_GET(self):
        url = urlparse(self.path)
        api = url.path.startswith('/api/')
        if not self._allowed(api):
            return
        repo = (parse_qs(url.query).get('repo') or [None])[0]
        if url.path == '/healthz':
            return self._send(200, {'ok': True, 'app': 'adlc-mission-control'})
        if url.path == '/api/state':
            try:
                return self._send(200, self.app.state(repo))
            except Exception as exc:
                traceback.print_exc()
                return self._send(500, {'error': 'The view could not be built (%s)' % type(exc).__name__})
        if url.path == '/api/meta':
            return self._send(200, self.app.meta())
        if url.path == '/api/events':
            return self._events(repo)
        return self._static(url.path)

    def _static(self, path):
        rel = 'index.html' if path in ('', '/') else path.lstrip('/')
        full = os.path.normpath(os.path.join(WEB, rel))
        if not full.startswith(WEB + os.sep) or not os.path.isfile(full):
            return self._send(404, {'error': 'Not found'})
        with open(full, 'rb') as fh:
            data = fh.read()
        ctype = mimetypes.guess_type(full)[0] or 'application/octet-stream'
        if ctype.startswith('text/') or ctype in ('application/javascript', 'application/json'):
            ctype += '; charset=utf-8'
        self._send(200, data, ctype)

    def _events(self, repo):
        """Server-Sent Events: the full state, again each time something changes. While the stream is open the
        repo counts as watched, which is what makes the poller read GitHub for it."""
        repo = self.app.repo(repo)
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Connection', 'close')
        self.end_headers()
        self.app.watch(repo, +1)
        seen = -1
        try:
            while True:
                with self.app.changed:
                    if self.app.version == seen:
                        self.app.changed.wait(timeout=10)
                    fresh = self.app.version != seen
                    seen = self.app.version
                chunk = ': keep-alive\n\n'   # also how a closed tab is noticed: the write fails
                if fresh:
                    try:
                        chunk = 'event: state\ndata: %s\n\n' % json.dumps(self.app.state(repo))
                    except Exception as exc:   # one row the view cannot digest must not end the stream for good
                        traceback.print_exc()
                        chunk = 'event: trouble\ndata: %s\n\n' % json.dumps({'error': 'The view could not be built (%s)' % type(exc).__name__})
                self.wfile.write(chunk.encode())
                self.wfile.flush()
                time.sleep(0.5)   # at most two pushes a second, however fast events arrive
        except OSError:           # the page went away
            pass
        finally:
            self.app.watch(repo, -1)

    # ---- POST: what Claude Code sends
    def do_POST(self):
        if not self._allowed(True):
            return
        path = urlparse(self.path).path
        if path not in ('/hooks', '/v1/logs', '/v1/metrics', '/v1/traces'):
            return self._send(404, {'error': 'Not found'})
        if 'json' not in (self.headers.get('Content-Type') or ''):
            return self._send(415, {'error': 'Send JSON. For telemetry set OTEL_EXPORTER_OTLP_PROTOCOL=http/json'})
        doc = self._json()
        if doc is None:
            return
        changed = False
        try:
            if path == '/hooks':
                changed = self.app.ingest.hook(doc)
            elif path == '/v1/logs':
                changed = self.app.ingest.otlp_logs(doc) > 0
        except Exception as exc:   # an event we cannot read is refused; it does not take the connection down with a traceback
            traceback.print_exc()
            return self._send(400, {'error': 'That event could not be read (%s)' % type(exc).__name__})
        if changed:
            self.app.bump()
        self._send(200, {})


def running_at(port):
    try:
        with urllib.request.urlopen('http://127.0.0.1:%d/healthz' % port, timeout=1.5) as res:
            return json.loads(res.read()).get('app') == 'adlc-mission-control'
    except (OSError, ValueError):
        return False


def marked(marker):
    """What the marker file says about a running copy: {'port', 'pid', ...}, or {} when there is none."""
    try:
        with open(marker) as fh:
            doc = json.load(fh)
        return doc if isinstance(doc, dict) else {}
    except (OSError, ValueError):
        return {}


def main(argv=None):
    ap = argparse.ArgumentParser(prog='adlc-mission-control', description='Live view of the ADLC pipeline for one repo, on this machine.')
    ap.add_argument('--repo', help='GitHub repo as owner/name. Default: the repo of the current directory.')
    ap.add_argument('--port', type=int, default=int(os.environ.get('ADLC_MC_PORT') or DEFAULT_PORT))
    ap.add_argument('--open', action='store_true', help='Open the page in the browser.')
    ap.add_argument('--demo', action='store_true', help='Show simulated work. Reads nothing, stores nothing, and agents do not report to it.')
    args = ap.parse_args(argv)

    # One place for the database and the marker, the same one hook.sh reads: ADLC_MC_HOME, or ~/.adlc/mission-control.
    home = ingest.data_home()
    marker = os.path.join(home, 'server.json')
    url = 'http://localhost:%d' % args.port + ('/?demo=1' if args.demo else '')
    if running_at(args.port):
        print('Mission Control is already running at ' + url)
        if args.open:
            webbrowser.open(url)
        return 0
    other = marked(marker).get('port')
    if not args.demo and isinstance(other, int) and running_at(other):
        # A second copy on the same data would take over the marker, and agents would stop reporting to the first.
        print('Mission Control is already running at http://localhost:%d. Stop it first to move it to port %d.' % (other, args.port))
        if args.open:
            webbrowser.open('http://localhost:%d' % other)
        return 0

    repo = (args.repo or ingest.Repos().lookup(os.getcwd())[0] or '').lower()
    if args.demo:
        store = Store()
    else:
        os.makedirs(home, exist_ok=True)
        store = Store(os.path.join(home, 'mc.sqlite'))
    app = App(store, repo, demo=args.demo)
    app.port = args.port
    Handler.app = app
    try:
        httpd = ThreadingHTTPServer(('127.0.0.1', args.port), Handler)
    except OSError as exc:
        print('Port %d is in use by something else (%s). Pick another with --port.' % (args.port, exc.strerror or exc))
        return 1
    httpd.daemon_threads = True

    def cleanup(*_):
        if marked(marker).get('pid') == os.getpid():   # only our own marker: never another copy's
            try:
                os.remove(marker)
            except OSError:
                pass
    if not args.demo:
        with open(marker, 'w') as fh:
            json.dump({'port': args.port, 'pid': os.getpid(), 'started': time.time()}, fh)
        atexit.register(cleanup)
    for sig in (signal.SIGTERM, signal.SIGHUP):   # a closed terminal counts as a stop, so the marker goes with it
        signal.signal(sig, lambda *_: sys.exit(0))

    print('Mission Control is running at ' + url)
    print('Repo: ' + (repo or 'none found here, pass --repo owner/name') + ('   (demo data)' if args.demo else ''))
    print('Press Ctrl+C to stop.')
    if args.open:
        webbrowser.open(url)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        cleanup()
    return 0


if __name__ == '__main__':
    sys.exit(main())
