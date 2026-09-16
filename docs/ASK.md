# Ask the wall

Open Tessera Codex, Settings, Services, Claude and paste an Anthropic API
key. Enable `[features] ask = true` in the Codex wall config. Type a question
on that page, or import [Ask the wall](../shortcuts/Ask%20the%20wall.shortcut)
on the phone and say its name to Siri. The Shortcut dictates, sends the
words to the wall and speaks the returned answer. The wall has no speaker.
Edit the URL in the Shortcut's first Text action if your wall has another
hostname. It defaults to `http://album-matrix.local:8788/ask`.

The Shortcut is signed for anyone using Apple's `shortcuts sign`. Its
reviewable source is `shortcuts/build.py` and its unsigned plist is included.
Signing verifies its container; spoken execution on the owner's iPhone still
needs an import, local-network permission and dictation permission.

## What the wall does

`POST /ask {"text": "What is playing?", "reply": "wall"}` returns
`{"answer": "...", "shown": true}`. `reply: text` returns the words without
putting an answer on the panel. Questions must be 1 to 2000 characters.
The service uses `claude-opus-5`, adaptive thinking and low effort, with the
official Python SDK. A single request occupies the worker; concurrent asks
get a short busy answer. Its wall state and journal tools read cached state.
Face, brightness and timer tools validate their bounds and act only within
the live request's time budget. The prompt tells Claude to change the wall
only when asked and to treat track names as data.

The HTTP response budget is 5.5 seconds plus local scheduling, leaving half
a second within the requested six-second budget. A slow network produces
`no answer right now`; it cannot produce a late panel takeover or execute
a late tool. It may already have performed a requested tool before another
round times out. Missing credentials show `no key yet` only once per process
until a key is supplied. Empty answers or refusal produce a short apology.
An actual Claude response inside the budget has not been measured without
the owner's key. This is a deadline with a quiet fallback, not a guarantee
that an external model always answers successfully in six seconds.

No questions or replies are saved. The key is owner-readable services.json,
never config.toml or the Shortcut. The SDK explicitly contacts Anthropic's
public API. The log records estimated cost from input and output token counts,
including billed thinking, using the standard $5/$25 per million rates
checked on 2026-09-15 against
[Anthropic's pricing](https://platform.claude.com/docs/en/about-claude/pricing).
`GET /services` reports key_set, model, busy, problem and last_cost_usd.

## The two panel layouts

The brief's requested character counts cannot fit the specified 5x7 glyphs
at 2x and 3x. This build preserves the larger lettering and adds pages.

- 64: 2x glyphs, one-pixel outer margin, 62-pixel line width, four lines.
  In the happy-path render, `The`, `rain`, `ends`, `at` begin at y=1, 17,
  33, 49. Their glyphs occupy fourteen-pixel-high bands. Each is centered;
  the second page puts `six.` at x=9, y=25. Every other pixel is black.
- 192: 3x glyphs, twelve-pixel margins, 168-pixel line width, up to seven
  lines. The happy-path render has `The rain` at x=25,y=61, `ends at` at
  x=34,y=85, and `six.` at x=61,y=109, each in a 21-pixel-high glyph band.
  Every other pixel is black. This is its own layout, not a scaled 64.

Foreground sRGB is (232,226,213), then the normal finish, white balance and
brightness pipeline apply. Pages last three seconds. The final page gets
four extra seconds, then the prior face returns. Any control change dismisses
the answer. The temporary face is not saved over the user's prior mode.

Both layouts and the no-key, network and empty-answer states were rendered
through the preview sink and inspected. `scripts/render_answers.py` rebuilds
them, their test geometry configs and `layout.json` under
`docs/verification/answers/`. No image model is used for these pixel renders.

## Deploy and test

Install the dependency in the Codex Pi venv:

```sh
/home/pi/wall-codex/.venv/bin/pip install 'anthropic>=0.70'
```

Copy `brain/ask.py`, `brain/art/answer.py`, `brain/art/loading.py`,
`brain/main.py`, `brain/control.py`, `brain/services.py` and
`brain/requirements.txt` to the same paths in `wall-codex`. The artwork loader
moves the existing sleeve fetch/decode off the drawing loop; it keeps one
pending request and the last prepared sleeve. This prevents an unrelated
slow art request from delaying an answer. Restart only the live Codex brain
by killing its systemd MainPID. Preserve the Pi config and pairing state.

Run `.venv/bin/python -m pytest brain/tests -q`. Offline tests cover wrapping
at both sizes, all tools, a fake-client tool round trip, text-only replies,
a missing key, persistent prior mode, late-tool suppression, Shortcut request
shape and the background artwork handoff. The iPhone installer remains
`tessera/Tools/install.sh codex`; Xcode currently needs a signing account
that can provision the separate Codex App Group.


## Leave a note

Import `shortcuts/Tell the wall.shortcut` on the iPhone. Say “Hey Siri, Tell
the wall”, then dictate the message. It sends `/state` with mode ticker,
across style and loop false, so the message crosses once then returns to
art. Its `_feature: note` marker checks this build's feature switch before
changing state. Enable `[features] note = true` first. The signed property
list is supplied; importing and running it on the owner's iPhone remains
pending. Dictation uses the phone's own Siri/Shortcuts privacy settings.

For a message that stays, POST `/note` with `{"text":"Back at six","minutes":30}`.
Minutes default to 30, accept fractions, and must be greater than zero and
at most 1440. Text is limited to 120 characters. It repeats in the across
ticker until expiry, then restores the previous face and ticker settings.
A control change cancels it immediately. Replacing a note keeps the original
return face. A restart restores the previous settings; notes are not saved.
No network service or API key is needed. First movement is on the next
render frame; text enters from the right at the existing ticker speed.

The existing Ticker is reused at both sizes. Native frames and enlarged
preview-sink renders in `docs/verification/notes` were inspected. At 64 the
14-pixel text band occupies y=25..38; at 192 its 42-pixel band occupies
y=75..116. Everything outside the moving letters is black. Render with
`.venv/bin/python -m scripts.render_notes`. Tests cover expiry, replacing
notes, cancellation, previous settings on disk, validation, the feature gate
and the Shortcut request shape. Install line: none beyond the brain's
existing requirements. Copy `brain/note.py` and `brain/control.py` to the
Codex Pi tree and restart its brain; no renderer change.
