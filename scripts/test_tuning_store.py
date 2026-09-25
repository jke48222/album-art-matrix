#!/usr/bin/env python3
"""Compile production TuningStore against real loopback HTTP servers to verify request ordering."""
from pathlib import Path
import json
import subprocess
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

root = Path(__file__).resolve().parents[1]
source = (root / 'tessera/Tessera/Tuning.swift').read_text()
source = 'import Foundation\nimport Observation\n' + source[source.index('struct Knob:'):source.index('struct PanelTuningPage:')]
servers = []
for identity in (1, 2):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args): pass
        def respond(self, value):
            data = json.dumps({'knobs': [], 'values': {'room_gate': value}, 'defaults': {}}).encode()
            self.send_response(200); self.send_header('Content-Type', 'application/json'); self.send_header('Content-Length', str(len(data))); self.end_headers(); self.wfile.write(data)
        def do_GET(self):
            self.server.gets += 1
            if self.server.identity == 1 and self.server.gets == 2: time.sleep(.35)
            self.respond(self.server.value)
        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', 0))))
            self.server.posts.append((self.path, body))
            time.sleep(.35)
            self.server.value = 9 if self.path.endswith('/reset') else body.get('room_gate', self.server.value)
            self.respond(self.server.value)
    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    server.identity = identity; server.gets = 0; server.posts = []; server.value = identity * 10
    threading.Thread(target=server.serve_forever, daemon=True).start(); servers.append(server)
main = r'''
import Foundation
@main struct Checks {
    @MainActor static func main() async {
        let store = TuningStore()
        let first = CommandLine.arguments[1], second = CommandLine.arguments[2]
        await store.load(host: first)
        precondition(store.values["room_gate"] == 10)
        let write = Task { await store.send("room_gate", 17) }
        try? await Task.sleep(for: .milliseconds(90))
        let start = Date()
        await store.load(host: first)
        precondition(Date().timeIntervalSince(start) < 0.1, "Refresh waits on an in-flight write")
        await write.value
        precondition(store.values["room_gate"] == 17, "Refresh invalidated the write acknowledgement")
        let reset = Task { await store.reset() }
        try? await Task.sleep(for: .milliseconds(90))
        precondition(store.busy)
        await store.send("room_gate", 99)
        await reset.value
        precondition(store.values["room_gate"] == 9, "A write raced reset")
        precondition(!store.busy)
        store.restartingUntil = Date().addingTimeInterval(50)
        let old = Task { await store.load(host: first) }
        try? await Task.sleep(for: .milliseconds(90))
        await store.load(host: second)
        await old.value
        precondition(store.values["room_gate"] == 20, "Old host response replaced new host")
        precondition(store.restartingUntil == nil, "Old wall restart state leaked")
        print("8 production TuningStore checks passed")
    }
}
'''
try:
    with tempfile.TemporaryDirectory(prefix='tessera-tuning-store-') as directory:
        directory = Path(directory)
        (directory / 'TuningStore.swift').write_text(source)
        (directory / 'Checks.swift').write_text(main)
        subprocess.run(['xcrun', 'swiftc', '-parse-as-library', str(directory / 'TuningStore.swift'), str(directory / 'Checks.swift'), '-o', str(directory / 'checks')], check=True)
        subprocess.run([str(directory / 'checks'), *[f'127.0.0.1:{s.server_port}' for s in servers]], check=True)
    assert servers[0].gets == 2 and servers[1].gets == 1, [s.gets for s in servers]
    assert [p for p, _ in servers[0].posts] == ['/tuning', '/tuning/reset'], servers[0].posts
    assert not servers[1].posts
    print('3 real HTTP ordering assertions passed')
finally:
    for server in servers: server.shutdown(); server.server_close()
