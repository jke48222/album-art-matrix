#!/usr/bin/env python3
"""Compile production TuningStore whole and drive it against real loopback
HTTP servers: request ordering, the renderer's states, the write-status
mapping, the legacy restart guess, formatting and the host switch."""
from pathlib import Path
import json
import subprocess
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

root = Path(__file__).resolve().parents[1]
# TuningStore reads /tuning's numbers through TuningPeek.numbers (the About
# page's), and AboutModels needs HomeDesign and WallGrid to compile.
sources = [root / 'tessera/Tessera' / name for name in
           ('TuningStore.swift', 'AboutModels.swift', 'HomeDesign.swift', 'WallGrid.swift')]

BUSY = 'The panel is still restarting. Try again in a moment.'
KNOBS = [
    {'name': 'bit_depth', 'group': 'Panel', 'kind': 'int', 'min': 4, 'max': 64, 'step': 4, 'restart': True,
     'note': 'More planes give smoother dim colours.', 'label': 'Bit depth', 'unit': 'planes', 'applies': 'restart'},
    {'name': 'panel_type', 'group': 'Panel', 'kind': 'int', 'min': 0, 'max': 7, 'step': 1, 'restart': True,
     'note': "Must match the panel's driver.", 'label': 'Row addressing', 'unit': None, 'applies': 'restart'},
    {'name': 'temporal_dither', 'group': 'Panel', 'kind': 'bool', 'min': 0, 'max': 1, 'step': 1, 'restart': True,
     'note': 'Redraws the picture.', 'label': 'Time dithering', 'unit': None, 'applies': 'restart'},
    {'name': 'dither_min', 'group': 'Panel', 'kind': 'float', 'min': 0.0, 'max': 0.5, 'step': 0.05, 'restart': True,
     'note': 'Steps smaller than this are rounded.', 'label': 'Smallest dithered step', 'unit': None, 'applies': 'restart'},
    {'name': 'black_point', 'group': 'Dark end', 'kind': 'int', 'min': 0, 'max': 48, 'step': 1, 'restart': False,
     'note': 'Levels at or below this are off.', 'label': 'Black point', 'unit': '/255', 'applies': 'now'},
    {'name': 'mic_gain', 'group': 'Hearing', 'kind': 'int', 'min': 0, 'max': 100, 'step': 5, 'restart': False,
     'note': 'The input gain.', 'label': 'Microphone gain', 'unit': '%', 'applies': 'listening'},
]
DEFAULTS = {'bit_depth': 64, 'panel_type': 0, 'temporal_dither': True, 'dither_min': 0.2, 'black_point': 0, 'mic_gain': 100}
GROUPS = [{'key': 'Panel', 'title': 'Panel drive', 'summary': "How the panel's rows are scanned.", 'tab': 'picture', 'pattern': 'darkSteps'},
          {'key': 'Dark end', 'title': 'Dark end', 'summary': 'The dimmest levels.', 'tab': 'picture', 'pattern': 'darkColours'},
          {'key': 'Hearing', 'title': 'Hearing', 'summary': 'The microphone.', 'tab': 'listening', 'pattern': None}]


def body(state='running', legacy=False, **values):
    out = {'values': {**DEFAULTS, **values}, 'defaults': dict(DEFAULTS), 'knobs': KNOBS}
    if legacy:
        out['restarting'] = state in ('restarting', 'starting')
        return out
    out.update({'groups': GROUPS, 'inactive': {'dither_min': 'Used only when Time dithering is on.', 'mic_gain': "The wall's microphone is off."},
                'renderer': {'state': state, 'down_s': None if state == 'running' else 2.0},
                'restarting': state in ('restarting', 'starting')})
    return out


# Each scene is the answers the scripted wall gives, one per request, in
# order. Once a scene runs out the wall answers plain running bodies.
SCENES = {
    'plain': [(200, body())],
    'busy': [(409, {'error': BUSY, **body('restarting', black_point=3)})],
    'rejected': [(200, {**body(black_point=3), 'rejected': ['black_point']})],
    'refused': [(503, {'error': 'The authored test wall could not confirm this change.'})],
    'silent': ['silent'],
    'legacy': [(200, body('restarting', legacy=True))],
    'restart': [(200, body('restarting', bit_depth=48))],
    'back': [(200, body('running', bit_depth=48))],
    'restart2': [(200, body('restarting', bit_depth=32))],
    'stalled': [(200, body('stalled', bit_depth=32))],
    'revert': [(200, body('restarting', bit_depth=48))],
    'reset': [(200, body('restarting'))],
    'resetback': [(200, body('running'))],
    'resetfail': [(500, {'error': 'Authored tuning failure'})],
    'kick': [(200, {'said': 'renderer relaunching (1 stopped)', **body('restarting')})],
    'unsupported': [(503, {'error': 'tuning is not available on this wall'})],
    'offline': [(503, {'error': 'Authored offline state'})],
    'bools': [(200, body(temporal_dither=False))],
    'starting': [(200, body('starting'))],
    'live': [(200, body(black_point=7))],
}

servers = []
# Servers 1 and 2: the request ordering the store has always had to keep.
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


# Server 3: a scripted wall. /__scene loads answers, /__requests lists what
# the store sent since the last /__clear.
class Scripted(BaseHTTPRequestHandler):
    def log_message(self, *args): pass

    def send_json(self, status, value):
        data = json.dumps(value).encode()
        self.send_response(status); self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data))); self.end_headers(); self.wfile.write(data)

    def answer(self, method, payload):
        with self.server.lock:
            if self.path.startswith('/__'):
                if self.path == '/__scene':
                    self.server.queue = list(SCENES[payload['name']])
                elif self.path == '/__clear':
                    self.server.requests = []
                self.send_json(200, {'requests': self.server.requests}); return
            self.server.requests.append({'method': method, 'path': self.path, 'body': payload})
            item = self.server.queue.pop(0) if self.server.queue else (200, body())
        if item == 'silent':
            self.close_connection = True
            return
        self.send_json(*item)

    def do_GET(self):
        self.answer('GET', None)

    def do_POST(self):
        length = int(self.headers.get('Content-Length', 0))
        self.answer('POST', json.loads(self.rfile.read(length) or b'{}'))


scripted = ThreadingHTTPServer(('127.0.0.1', 0), Scripted)
scripted.lock = threading.Lock(); scripted.queue = []; scripted.requests = []
threading.Thread(target=scripted.serve_forever, daemon=True).start()

main = r'''
import Foundation

var passed = 0
func check(_ ok: Bool, _ name: String) {
    guard ok else { FileHandle.standardError.write(Data("FAILED: \(name)\n".utf8)); exit(1) }
    passed += 1
}

/// Talks to the scripted wall's own controls.
func wall(_ host: String, _ path: String, _ payload: [String: Any] = [:]) async -> [[String: Any]] {
    var request = URLRequest(url: URL(string: "http://\(host)\(path)")!)
    request.httpMethod = "POST"
    request.httpBody = try! JSONSerialization.data(withJSONObject: payload)
    let (data, _) = try! await URLSession.shared.data(for: request)
    return ((try! JSONSerialization.jsonObject(with: data)) as! [String: Any])["requests"] as! [[String: Any]]
}
func scene(_ host: String, _ name: String) async { _ = await wall(host, "/__scene", ["name": name]); _ = await wall(host, "/__clear") }
func sent(_ host: String) async -> [[String: Any]] { await wall(host, "/__requests") }
func gets(_ list: [[String: Any]]) -> Int { list.filter { $0["method"] as? String == "GET" }.count }
func posts(_ list: [[String: Any]]) -> [[String: Any]] { list.filter { $0["method"] as? String == "POST" } }

@main struct Checks {
    @MainActor static func main() async {
        let first = CommandLine.arguments[1], second = CommandLine.arguments[2], scripted = CommandLine.arguments[3]

        // Ordering, kept from the store's first tests.
        let store = TuningStore()
        await store.load(host: first)
        check(store.values["room_gate"] == 10, "first read")
        let write = Task { await store.send("room_gate", 17) }
        try? await Task.sleep(for: .milliseconds(90))
        let start = Date()
        await store.load(host: first)
        check(Date().timeIntervalSince(start) < 0.1, "Refresh waits on an in-flight write")
        await write.value
        check(store.values["room_gate"] == 17, "Refresh invalidated the write acknowledgement")
        let reset = Task { await store.reset() }
        try? await Task.sleep(for: .milliseconds(90))
        check(store.busy && store.resetting, "busy while resetting")
        await store.send("room_gate", 99)
        check(await reset.value, "the reset was taken")
        check(store.values["room_gate"] == 9, "A write raced reset")
        check(!store.busy, "busy clears")
        let old = Task { await store.load(host: first) }
        try? await Task.sleep(for: .milliseconds(90))
        await store.load(host: second)
        await old.value
        check(store.values["room_gate"] == 20, "Old host response replaced new host")

        // The scripted wall.
        var lines: [String] = []
        let tuned = TuningStore()
        tuned.log = { lines.append($0) }
        await scene(scripted, "plain")
        await tuned.load(host: scripted)
        check(tuned.knobs.count == 6 && tuned.renderer == .running, "a full body is read")
        check(tuned.groups.map(\.key) == ["Panel", "Dark end", "Hearing"], "groups in the brain's order")
        check(tuned.inactive["dither_min"] == "Used only when Time dithering is on.", "inactive reasons")
        // The wall's straight apostrophes read as the app's curly one.
        check(tuned.knobs.first { $0.name == "panel_type" }?.note == "Must match the panel\u{2019}s driver.", "a note's apostrophe is curly")
        check(tuned.groups.first?.summary == "How the panel\u{2019}s rows are scanned.", "a summary's apostrophe is curly")
        check(tuned.inactive["mic_gain"] == "The wall\u{2019}s microphone is off.", "a reason's apostrophe is curly")
        check(!tuned.knobs.contains { $0.note.contains("'") || $0.title.contains("'") }, "no straight apostrophe is left")
        check(tuned.changedCount == 0 && tuned.lastRead != nil && tuned.readFailures == 0, "at defaults")
        check(tuned.values["temporal_dither"] == 1, "JSON true is 1")

        // Formatting, from the step's own decimals and the unit's own spacing.
        func knob(_ name: String) -> Knob { tuned.knobs.first { $0.name == name }! }
        check(tuned.format(value: 0.2, knob: knob("dither_min")) == "0.20", "0.05 step gives 2 decimals, no unit")
        check(tuned.format(value: 48, knob: knob("bit_depth")) == "48 planes", "a step of 4 gives none")
        check(tuned.format(value: 12, knob: knob("black_point")) == "12/255", "/255 joins without a space")
        check(tuned.format(value: 60, knob: knob("mic_gain")) == "60%", "% joins without a space")
        check(tuned.format(value: 3, knob: knob("panel_type")) == "3", "no unit")
        check(tuned.format(value: 1, knob: knob("temporal_dither")) == "On", "bools read On")
        let settle = Knob(name: "addr_settle_ns", group: "Panel", kind: "int", min: 0, max: 2000, step: 25, restart: true, note: "", label: "Row settle time", unit: "ns")
        check(tuned.format(value: 1000, knob: settle) == "1000 ns", "a step of 25 gives none, ns with a space")
        let clip = Knob(name: "listen_for", group: "Hearing", kind: "float", min: 3, max: 12, step: 0.5, restart: false, note: "", unit: "s")
        check(tuned.format(value: 6, knob: clip) == "6.0 s", "a step of 0.5 gives 1 decimal")
        check(TuningStore.spoken(12, knob: knob("black_point")) == "12 out of 255", "spoken /255")
        check(TuningStore.spoken(60, knob: knob("mic_gain")) == "60 percent", "spoken %")
        check(TuningStore.spoken(1000, knob: settle) == "1000 nanoseconds", "spoken ns")
        check(knob("panel_type").isChoice && !knob("bit_depth").isChoice && knob("bit_depth").positions == 16, "positions")
        check(Knob(name: "low_blue", group: "Dark end", kind: "float", min: 0, max: 1, step: 0.01, restart: false, note: "").title == "Low blue", "title fallback")
        check(knob("bit_depth").title == "Bit depth" && knob("bit_depth").applies == "restart", "label and applies")

        // A VoiceOver step, the math TuningRail and -tuning-adjust share.
        check(TuningStore.stepped(64, up: false, knob: knob("bit_depth")) == 60, "a step down")
        check(TuningStore.stepped(64, up: true, knob: knob("bit_depth")) == 64, "a step up at the top stays")
        check(TuningStore.stepped(4, up: false, knob: knob("bit_depth")) == 4, "a step down at the bottom stays")
        check(TuningStore.stepped(0.2, up: true, knob: knob("dither_min")) == 0.25, "a 0.05 step lands on 0.25 exactly")
        check(TuningStore.stepped(0.5, up: true, knob: knob("dither_min")) == 0.5, "held at the top of a float range")
        check(TuningStore.clamped(-3, knob: knob("dither_min")) == 0 && TuningStore.clamped(12.4, knob: knob("black_point")) == 12, "clamped and rounded to the step")

        // 409: the body is the wall's, and the row says why.
        await scene(scripted, "busy")
        await tuned.send("bit_depth", 48)
        check(tuned.rowProblems["bit_depth"] == "The panel is still restarting. Try again in a moment.", "409 row problem")
        check(tuned.problem == tuned.rowProblems["bit_depth"], "409 also sets problem")
        check(tuned.values["black_point"] == 3 && tuned.values["bit_depth"] == 64, "409 values are taken")
        check(tuned.renderer == .restarting && tuned.panelState == .restarting, "409 renderer taken")
        check(tuned.changedCount == 1 && tuned.changed(in: "Dark end") == 1 && tuned.changed(in: "Panel") == 0, "changedCount")

        // 200 with the key rejected: that row only, then one read.
        await scene(scripted, "rejected")
        await tuned.send("black_point", 5)
        var log = await sent(scripted)
        check(tuned.rowProblems["black_point"] == "The wall did not accept this value. It is still using the one shown.", "rejected row")
        check(tuned.problem == tuned.rowProblems["black_point"], "rejected sets problem")
        check(posts(log).count == 1 && gets(log) == 1, "one refresh after a rejection")
        check(tuned.rowProblems["bit_depth"] == nil, "the restarting problem went when the answer said running")

        // 503 and no answer.
        await scene(scripted, "refused")
        await tuned.send("mic_gain", 60)
        log = await sent(scripted)
        check(tuned.rowProblems["mic_gain"] == "The wall did not accept this value. It is still using the one shown.", "503 is refused")
        check(tuned.problem == tuned.rowProblems["mic_gain"] && gets(log) == 1 && tuned.values["mic_gain"] == 100, "503 refreshes once, value stays")
        await scene(scripted, "silent")
        await tuned.send("mic_gain", 60)
        log = await sent(scripted)
        check(tuned.rowProblems["mic_gain"] == "The change was not confirmed. The value shown is the last one the wall reported.", "no answer is not confirmed")
        check(tuned.problem == tuned.rowProblems["mic_gain"] && gets(log) == 1, "no answer refreshes once")
        check(tuned.rowProblems["black_point"] != nil, "another row's problem stays until it is written")
        await scene(scripted, "plain")
        await tuned.send("mic_gain", 100)
        check(tuned.rowProblems["mic_gain"] == nil && tuned.problem == nil, "an accepted write clears its row")

        // A launch flag, back, then one that stalls and is put back.
        lines = []
        await scene(scripted, "restart")
        await tuned.send("bit_depth", 48)
        check(tuned.renderer == .restarting && lines.contains("bit_depth=48 restart"), "restart logged")
        check(tuned.lastRevert == TuningRevert(name: "bit_depth", previous: 64), "revert remembered")
        await scene(scripted, "back")
        await tuned.refresh(host: scripted)
        check(tuned.renderer == .running && tuned.justBack != nil && tuned.justBackCause == .setting, "back after a setting")
        check(lines.contains { $0.hasPrefix("renderer back after ") && $0.hasSuffix(" s") }, "back logged")
        check(tuned.rowProblems["bit_depth"] == nil, "a stale restarting problem clears when the panel is back")
        await scene(scripted, "restart2")
        await tuned.send("bit_depth", 32)
        await scene(scripted, "stalled")
        await tuned.refresh(host: scripted)
        check(tuned.renderer == .stalled && lines.contains("renderer stalled"), "stalled logged")
        check(tuned.lastRevert == TuningRevert(name: "bit_depth", previous: 48), "revert is the last launch flag")
        await scene(scripted, "revert")
        await tuned.revert()
        log = await sent(scripted)
        check(posts(log).count == 1 && (posts(log)[0]["body"] as? [String: Any])?.keys.sorted() == ["bit_depth"], "revert sends only that key")
        check(((posts(log)[0]["body"] as? [String: Any])?["bit_depth"] as? Double) == 48, "revert sends the previous value")
        check(tuned.lastRevert == nil, "revert is spent")
        await scene(scripted, "back")
        await tuned.refresh(host: scripted)

        // Reset and restart.
        lines = []
        await scene(scripted, "reset")
        await tuned.reset()
        check(lines.contains("reset") && tuned.renderer == .restarting && tuned.rowProblems.isEmpty, "reset")
        await scene(scripted, "resetback")
        await tuned.refresh(host: scripted)
        check(tuned.justBackCause == .reset, "back after a reset")
        await scene(scripted, "resetfail")
        await tuned.reset()
        log = await sent(scripted)
        check(tuned.problem == "The reset was not confirmed. The values shown are what the wall reports now." && gets(log) == 1, "reset not confirmed")
        await scene(scripted, "kick")
        await tuned.restartPanel()
        check(tuned.renderer == .restarting && lines.contains("restart: renderer relaunching (1 stopped)"), "restart the panel")

        // Holding and busy skip the poll.
        await scene(scripted, "plain")
        tuned.holding = true
        await tuned.refresh(host: scripted)
        check(gets(await sent(scripted)) == 0, "no refresh while a finger is down")

        // A drag's live writes are not logged. Its release is, once.
        lines = []
        await scene(scripted, "live")
        await tuned.send("black_point", 7)
        check(tuned.values["black_point"] == 7 && !lines.contains { $0.hasPrefix("black_point=") }, "a live write is not logged")
        tuned.holding = false
        tuned.noteCommitted("black_point")
        check(lines.filter { $0.hasPrefix("black_point=") } == ["black_point=7"], "the release is logged once")
        await scene(scripted, "plain")
        await tuned.send("black_point", 0)
        check(lines.filter { $0.hasPrefix("black_point=") } == ["black_point=7", "black_point=0"], "a write with no finger down is logged")

        // A stall that clears by itself is a return too, and spends its
        // cause, so a later start is not announced with the old one.
        let again = TuningStore()
        var told: [String] = []
        again.log = { told.append($0) }
        await scene(scripted, "plain")
        await again.load(host: scripted)
        await scene(scripted, "restart")
        await again.send("bit_depth", 48)
        await scene(scripted, "stalled")
        await again.refresh(host: scripted)
        check(again.renderer == .stalled && again.justBack == nil, "stalled before it clears")
        await scene(scripted, "back")
        await again.refresh(host: scripted)
        check(again.renderer == .running && again.justBack != nil && again.justBackCause == .setting, "stalled to running is back")
        check(told.contains { $0.hasPrefix("renderer back") }, "stalled to running is logged")
        check(again.lastRevert == TuningRevert(name: "bit_depth", previous: 64), "a setting's revert is kept, as after a restart")
        let firstBack = again.justBack
        await scene(scripted, "starting")
        await again.refresh(host: scripted)
        await scene(scripted, "back")
        await again.refresh(host: scripted)
        check(again.justBack != firstBack && again.justBackCause == nil, "a later start does not reuse the old cause")
        check(again.lastRevert == nil, "a later start drops the old launch flag")

        // A legacy brain: no renderer, no groups, a 7 s guess.
        let legacy = TuningStore()
        await scene(scripted, "legacy")
        await legacy.load(host: scripted)
        let ahead = legacy.legacyRestartUntil.map { $0.timeIntervalSinceNow } ?? 0
        check(ahead > 6.5 && ahead <= 7.01, "legacy restart window is about 7 s")
        check(legacy.renderer == .unknown && legacy.panelState == .restarting, "legacy restarting")
        check(legacy.groups.map(\.key) == ["Panel", "Dark end", "Hearing"] && legacy.groups[0].title == "Panel drive", "built-in groups")

        // Unsupported only before any read, and only for the exact answer.
        let bare = TuningStore()
        await scene(scripted, "unsupported")
        await bare.load(host: scripted)
        check(bare.unsupported && !bare.readFailed && bare.knobs.isEmpty, "503 unsupported before any read")
        let away = TuningStore()
        await scene(scripted, "offline")
        await away.load(host: scripted)
        check(!away.unsupported && away.readFailed, "a different 503 is a read error")
        let read = TuningStore()
        await scene(scripted, "plain")
        await read.load(host: scripted)
        await scene(scripted, "unsupported")
        await read.refresh(host: scripted)
        check(!read.unsupported && read.readFailures == 1 && read.knobs.count == 6, "after a read, 503 is a failed refresh")
        await scene(scripted, "offline")
        await read.refresh(host: scripted)
        check(read.readFailures == 2 && read.values["bit_depth"] == 64, "failed refreshes count and keep values")
        await scene(scripted, "plain")
        await read.refresh(host: scripted)
        check(read.readFailures == 0, "an answer resets the count")

        // A host switch forgets the old wall's renderer and problems.
        await scene(scripted, "busy")
        await read.send("bit_depth", 48)
        await scene(scripted, "legacy")
        await read.refresh(host: scripted)
        check(!read.rowProblems.isEmpty && read.legacyRestartUntil != nil, "state to forget")
        await read.load(host: second)
        check(read.renderer == .unknown && read.rowProblems.isEmpty && read.justBack == nil && read.legacyRestartUntil == nil, "host switch clears")
        check(read.lastRevert == nil && read.values["room_gate"] == 20, "host switch reads the new wall")

        // Copy.
        check(TuningCopy.changed(0) == "All settings at their defaults", "at defaults copy")
        check(TuningCopy.changed(1) == "1 setting changed from its default", "singular copy")
        check(TuningCopy.changed(3) == "3 settings changed from their defaults", "plural copy")
        check(TuningCopy.ago(40) == "40 seconds ago" && TuningCopy.ago(60) == "1 minute ago" && TuningCopy.ago(125) == "2 minutes ago", "ago")
        check(TuningCopy.applies("next_video") == "Applies from the next video." && TuningCopy.applies("now") == nil, "applies lines")
        // A run of rows with one scope says it once, on its first row. A row
        // with none in between starts a new run.
        let art = TuningCopy.applies("sleeves"), played = TuningCopy.applies("video")
        let scoped = TuningCopy.scopes([nil, art, art, art, played, nil, art])
        check(scoped == [nil, art, nil, nil, played, nil, art], "a repeated scope line is said once")
        check(TuningCopy.scopes([]).isEmpty, "no rows, no scopes")

        // Start over names only what a reset changes.
        let changedBoth = TuningCopy.resetQuestion(anyChanged: true, restarts: true,
                                                   named: [("Spatial dither", "0.0"), ("Row settle time", "0 ns")])
        check(changedBoth == "Return every panel and listening setting to its default? The panel restarts once. Your True colour correction stays as it is. Spatial dither goes back to 0.0 and Row settle time to 0 ns.", "both named")
        let changedOne = TuningCopy.resetQuestion(anyChanged: true, restarts: true, named: [("Row settle time", "0 ns")])
        check(changedOne.hasSuffix(" Row settle time goes back to 0 ns.") && !changedOne.contains("Spatial dither"), "one named")
        let changedNone = TuningCopy.resetQuestion(anyChanged: true, restarts: true, named: [])
        check(changedNone == "Return every panel and listening setting to its default? The panel restarts once. Your True colour correction stays as it is.", "none named")
        let atDefaults = TuningCopy.resetQuestion(anyChanged: false, restarts: true, named: [])
        check(atDefaults == "Every setting is already at its default. Returning to defaults only restarts the panel. Your True colour correction stays as it is.", "nothing to put back")
        let noPanel = TuningCopy.resetQuestion(anyChanged: true, restarts: false, named: [])
        check(!noPanel.contains("restart"), "no restart promised without a panel program")
        check(TuningCopy.resetQuestion(anyChanged: false, restarts: false, named: []).contains("changes nothing"), "nothing at all")
        check(TuningCopy.startOver(restarts: true).contains("The panel restarts once.") && !TuningCopy.startOver(restarts: false).contains("restart"), "start over follows the panel")
        let banned: [Character] = [";", "\u{2014}", "\u{2013}", "\u{00B7}", "\u{00D7}"]
        let copy = [TuningCopy.refused, TuningCopy.restarting, TuningCopy.notConfirmed, TuningCopy.resetNotConfirmed,
                    changedBoth, atDefaults, noPanel, TuningCopy.startOver(restarts: true), TuningCopy.startOver(restarts: false)]
            + ["sleeves", "next_sleeve", "next_video", "video"].compactMap(TuningCopy.applies)
            + TuningGroup.builtIn.flatMap { [$0.title, $0.summary] }
        check(copy.allSatisfy { !$0.contains { banned.contains($0) } }, "copy has no banned punctuation")
        print("\(passed) production TuningStore checks passed")
    }
}
'''

try:
    with tempfile.TemporaryDirectory(prefix='tessera-tuning-store-') as directory:
        directory = Path(directory)
        (directory / 'Checks.swift').write_text(main)
        subprocess.run(['xcrun', 'swiftc', '-parse-as-library', *map(str, sources), str(directory / 'Checks.swift'),
                        '-o', str(directory / 'checks')], check=True)
        subprocess.run([str(directory / 'checks'), *[f'127.0.0.1:{s.server_port}' for s in servers],
                        f'127.0.0.1:{scripted.server_port}'], check=True, timeout=120)
    assert servers[0].gets == 2 and servers[1].gets == 2, [s.gets for s in servers]
    assert [p for p, _ in servers[0].posts] == ['/tuning', '/tuning/reset'], servers[0].posts
    assert not servers[1].posts
    print('3 real HTTP ordering assertions passed')
finally:
    for server in [*servers, scripted]: server.shutdown(); server.server_close()
