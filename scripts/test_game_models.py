#!/usr/bin/env python3
"""Compile production game models and test real HTTP acknowledgement contracts."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--json', type=Path, default=root / 'qa/batch-09/game-native-tests.json')
args = parser.parse_args()
args.json.parent.mkdir(parents=True, exist_ok=True)
active = {'running': True, 'seq': 12, 'session_id': 'session-A', 'on_wall': True,
          'game': {'name': 'wordle', 'title': 'Wordle', 'players': ['You'], 'seq': 2, 'rows': []}}
requests = []


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def reply(self, code, body):
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        try: self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError): pass
    def do_GET(self):
        requests.append(('GET', self.path, None))
        if self.path == '/game/list':
            self.server.catalogue_calls += 1
            cards = [dict(name=name, title=title, blurb='A real game.', players=players, voice=True)
                     for name, title, players in [('wordle', 'Wordle', [1, 4]), ('sudoku', 'Sudoku', [1, 1]), ('pictionary', 'Pictionary', [1, 8])]]
            if self.server.catalogue_calls == 2: cards.append(cards[0])
            if self.server.catalogue_calls == 3: cards[0]['players'] = [9223372036854775807, 9223372036854775807]
            # The fourth read is a wall with games switched off.
            if self.server.catalogue_calls == 4:
                self.reply(200, {'running': False, 'games': [], 'problem': 'games are off on this wall'})
                return
            self.reply(200, {'games': cards})
        elif self.path == '/game':
            self.server.status_calls += 1
            self.reply(200, active if self.server.status_calls == 1 else {'error': 'No status available'} if self.server.status_calls == 2 else b'{broken')
        else: self.reply(404, {'error': 'not found'})
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', 0))))
        requests.append(('POST', self.path, body))
        if self.path == '/game/denied': self.reply(409, {**active, 'error': 'The game changed. Refresh before making another move.'})
        elif self.path == '/game/empty': self.reply(200, {})
        elif self.path == '/game/malformed': self.reply(200, b'not json')
        elif self.path == '/game/error-ok': self.reply(200, {**active, 'error': 'Not a word.'})
        elif self.path == '/game/slow':
            time.sleep(.6); self.reply(200, {**active, 'seq': 13})
        else: self.reply(200, {**active, 'seq': 13})


server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
server.catalogue_calls = 0
server.status_calls = 0
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    with tempfile.TemporaryDirectory(prefix='tessera-game-models-') as directory:
        binary = Path(directory) / 'game-tests'
        subprocess.run(['xcrun', 'swiftc', '-parse-as-library', str(root / 'tessera/Tessera/GameModels.swift'),
                        str(root / 'scripts/test_game_models.swift'), '-o', str(binary)], check=True)
        result = subprocess.run([str(binary), f'127.0.0.1:{server.server_port}', str(args.json.resolve())])
    output = json.loads(args.json.read_text())
    posts = [(path, body) for method, path, body in requests if method == 'POST']
    extra = [
        {'name': 'POST failures are never retried', 'passed': len([p for p, _ in posts if p == '/game/denied']) == 1},
        {'name': 'session and move survive HTTP serialization', 'passed': all(body == {'session_id': 'session-A', 'player': 'You', 'move': {'guess': 'crane'}} for _, body in posts)},
        {'name': 'cancelled request was issued only once', 'passed': len([p for p, _ in posts if p == '/game/slow']) == 1},
    ]
    output['checks'].extend(extra)
    output['passed'] = sum(check['passed'] for check in output['checks'])
    output['failed'] = len(output['checks']) - output['passed']
    args.json.write_text(json.dumps(output, indent=2) + '\n')
    print(f"HTTP fixture assertions: {sum(check['passed'] for check in extra)}/{len(extra)} passed")
    if result.returncode or output['failed']: raise SystemExit(1)
finally:
    server.shutdown(); server.server_close()
