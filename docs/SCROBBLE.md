# The records you heard

Enable `[features] scrobble = true` in this build's Pi config, then open
Tessera Codex, Settings, Services, ListenBrainz. Paste the user token from
[ListenBrainz settings](https://listenbrainz.org/settings/). The username
reads streamed songs; the token reports records. Clearing the token stops
reporting. It never comes back in an API response and is kept in the wall's
services.json with owner-only permissions.

The ear announces a newly named song on the worker's next quarter-second
tick. Half the duration, capped at four minutes, earns a permanent listen.
Unknown lengths require four minutes. Only time with the ear's gate open
counts. A silence or recognition hold does not manufacture another play.
A fresh recognition after the estimated end can begin another performance.
Network time is additional; a stalled request runs on a separate transport
thread and cannot stall hearing-time accounting or rendering. The phone
refreshes status every two seconds.

## What stays on the wall

In `~/.config/album-art-matrix/`:

- `scrobbles.jsonl`: failed announcements and qualified listens, at most seven
  days old. Announcements expire after four minutes or when their song leaves.
  They are never imported as unearned listens.
- `scrobble-state.json`: hearing progress, dedupe receipts and last successful
  listen. Receipts expire after seven days. Hearing progress checkpoints every
  five seconds; an abrupt power loss may require up to five extra seconds.
- `journal.jsonl`: an ear sleeve includes `source: ears` and `scrobbled`, set
  true when ListenBrainz accepts its listen. Journal persistence runs off the
  drawing loop.

There is no audio in these files. Retries wait 1, 5, 15 minutes, then an hour.
The server's longer numeric Retry-After wins. Qualified retries use `import`
with at most 50 listens. Other 4xx responses are logged and dropped. An
accepted request with a lost response can be retried with the same identity
and timestamp; no client can guarantee exactly-once remote writes over a
broken connection. Missing tokens keep the queue, and disabling the feature
prevents new requests. A request already sent may still finish.

The payload follows the official
[ListenBrainz JSON documentation](https://listenbrainz.readthedocs.io/en/latest/users/json.html).

## Install and verify

No Python dependency was added. Run:

```sh
.venv/bin/python -m pytest brain/tests/test_scrobble.py -q
```

Deploy `brain/features.py`, `brain/scrobble.py`, `brain/services.py`,
`brain/control.py`, `brain/main.py`, `brain/nowplaying/__init__.py`, and
`brain/nowplaying/ears.py` to those exact paths in `/home/pi/wall-codex`.
Copy one file at a time and compare local `md5 -q` to remote `md5sum`.
Do not copy the Mac config: edit only `[features]` and `[scrobble]` in the
Codex Pi config. The feature watcher notices switches within one second.

The brain needs a restart for the code: when Codex is live, read
`systemctl show album-art-matrix -p MainPID --value` and `kill -KILL` that
PID. systemd brings it back in five seconds. For the first switch, run
`/home/pi/wall-codex/pi/switch.sh codex`. Pairing state is never modified.
Build and install the separate app with `tessera/Tools/install.sh codex`.
The installer isolates bundle IDs, app group, deep links and OAuth callback
scheme. Spotify for this build needs `tessera-codex://spotify` registered.

Check `/features`, `/services` and `/journal` on port 8788. The panel has no
new drawing for this feature; there are no 64/192 preview images to inspect.
A live successful listen still requires the owner's user token and a record
heard long enough. Resource use and real network latency must be measured on
the Pi separately from the offline logic tests.
