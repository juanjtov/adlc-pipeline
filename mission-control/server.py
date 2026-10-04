#!/usr/bin/env python3
"""ADLC Mission Control: a local, read-only live view of the pipeline.

Standard library only (Python 3.9+). It listens on 127.0.0.1, receives what Claude Code sends
(hook events and telemetry), reads GitHub through `gh`, and serves one page that shows it all.
"""
import argparse
import atexit
import gzip
import json
import mimetypes
import os
import signal
import sys
import threading
import time
import urllib.request
import webbrowser
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


class App:
    """Everything the request handlers share."""

    def __init__(self, store, repo, demo=False, poll=True, interval=15.0):
        self.store, self.demo = store, demo
        self.default_repo = repo
        self.port = DEFAULT_PORT
        self.changed = threading.Condition()
        self.version = 0
        self.agents = {st: pipeline.read_agent(PLUGIN_ROOT, st) for st in pipeline.STATIONS}
        self.ingest = ingest.Ingest(store, on_repo=self._seen_repo)
        if repo:
            store.add_repo(repo)
        self.poller = github.Poller(store, store.repos, self.bump, interval=interval)
        if poll and not demo:
            self.poller.start()

    def _seen_repo(self, repo):
        if repo not in self.store.repos():
            self.store.add_repo(repo)
            self.poller.wake.set()

    def bump(self):
        with self.changed:
            self.version += 1
            self.changed.notify_all()

    def repo(self, wanted=None):
        repos = self.store.repos()
        if wanted in repos:
            return wanted
        return self.default_repo or (repos[0] if repos else '')

    def state(self, wanted=None):
        repo = self.repo(wanted)
        mode = 'demo' if self.demo else 'live'
        return state.build(self.store, repo, agents=self.agents, github=self.poller.status.get(repo), mode=mode)

    def meta(self):
        return {'stations': [self.agents[st] for st in pipeline.STATIONS], 'demo': self.demo, 'port': self.port}


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    server_version = 'adlc-mission-control'
    app = None

    def log_message(self, fmt, *args):   # quiet: one line per request is noise for a local tool
        pass

    # ---- guards: this server is for this machine only
    def _local(self):
        host = (self.headers.get('Host') or '').split(':')[0]
        if host not in ('localhost', '127.0.0.1', '[::1]'):
            self._send(403, {'error': 'Mission Control only answers on localhost'})
            return False
        return True

    def _same_origin(self):
        """Claude Code and curl send no Origin. A web page on another site does, and is refused."""
        origin = self.headers.get('Origin')
        if origin and urlparse(origin).netloc != self.headers.get('Host'):
            self._send(403, {'error': 'Cross-site requests are not accepted'})
            return False
        return True

    def _send(self, code, body, ctype='application/json'):
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(code)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(data)

    def _body(self):
        length = int(self.headers.get('Content-Length') or 0)
        if length <= 0 or length > MAX_BODY:
            return None
        raw = self.rfile.read(length)
        if (self.headers.get('Content-Encoding') or '').lower() == 'gzip':
            raw = gzip.decompress(raw)
        try:
            return json.loads(raw.decode('utf-8'))
        except (ValueError, UnicodeDecodeError):
            return None

    # ---- GET
    def do_GET(self):
        if not self._local():
            return
        url = urlparse(self.path)
        query = parse_qs(url.query)
        repo = (query.get('repo') or [None])[0]
        if url.path == '/healthz':
            return self._send(200, {'ok': True, 'app': 'adlc-mission-control'})
        if url.path == '/api/state':
            return self._send(200, self.app.state(repo))
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
        """Server-Sent Events: the full state, again each time something changes."""
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Connection', 'keep-alive')
        self.end_headers()
        seen = -1
        try:
            while True:
                with self.app.changed:
                    if self.app.version == seen:
                        self.app.changed.wait(timeout=10)
                    fresh = self.app.version != seen
                    seen = self.app.version
                payload = json.dumps(self.app.state(repo)) if fresh else None
                chunk = ('event: state\ndata: %s\n\n' % payload) if payload else ': keep-alive\n\n'
                self.wfile.write(chunk.encode())
                self.wfile.flush()
                time.sleep(0.5)   # at most two pushes a second, however fast events arrive
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass

    # ---- POST: what Claude Code sends
    def do_POST(self):
        if not self._local() or not self._same_origin():
            return
        path = urlparse(self.path).path
        if path not in ('/hooks', '/v1/logs', '/v1/metrics', '/v1/traces'):
            return self._send(404, {'error': 'Not found'})
        if 'json' not in (self.headers.get('Content-Type') or ''):
            return self._send(415, {'error': 'Send JSON. For telemetry set OTEL_EXPORTER_OTLP_PROTOCOL=http/json'})
        doc = self._body()
        if doc is None:
            return self._send(400, {'error': 'The body is not valid JSON'})
        changed = False
        if path == '/hooks':
            changed = self.app.ingest.hook(doc)
        elif path == '/v1/logs':
            changed = self.app.ingest.otlp_logs(doc) > 0
        if changed:
            self.app.bump()
        self._send(200, {})


def running_at(port):
    try:
        with urllib.request.urlopen('http://127.0.0.1:%d/healthz' % port, timeout=1.5) as res:
            return json.loads(res.read()).get('app') == 'adlc-mission-control'
    except (OSError, ValueError):
        return False


def main(argv=None):
    ap = argparse.ArgumentParser(prog='adlc-mission-control', description='Live view of the ADLC pipeline for one repo, on this machine.')
    ap.add_argument('--repo', help='GitHub repo as owner/name. Default: the repo of the current directory.')
    ap.add_argument('--port', type=int, default=int(os.environ.get('ADLC_MC_PORT') or DEFAULT_PORT))
    ap.add_argument('--open', action='store_true', help='Open the page in the browser.')
    ap.add_argument('--demo', action='store_true', help='Show simulated work instead of reading GitHub.')
    ap.add_argument('--home', default=ingest.data_home(), help='Where the database lives. Default: ~/.adlc/mission-control')
    args = ap.parse_args(argv)

    url = 'http://localhost:%d' % args.port + ('/?demo=1' if args.demo else '')
    if running_at(args.port):
        print('Mission Control is already running at ' + url)
        if args.open:
            webbrowser.open(url)
        return 0

    os.makedirs(args.home, exist_ok=True)
    repo = args.repo or ingest.Repos().lookup(os.getcwd())[0]
    app = App(Store(os.path.join(args.home, 'mc.sqlite')), repo, demo=args.demo)
    app.port = args.port
    Handler.app = app
    try:
        httpd = ThreadingHTTPServer(('127.0.0.1', args.port), Handler)
    except OSError as exc:
        print('Port %d is in use by something else (%s). Pick another with --port.' % (args.port, exc.strerror or exc))
        return 1
    httpd.daemon_threads = True

    marker = os.path.join(args.home, 'server.json')
    with open(marker, 'w') as fh:
        json.dump({'port': args.port, 'pid': os.getpid(), 'started': time.time()}, fh)

    def cleanup(*_):
        try:
            os.remove(marker)
        except OSError:
            pass
    atexit.register(cleanup)
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))

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
