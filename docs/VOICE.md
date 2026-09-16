# The wall's own voice controls

Say “hey jarvis”, pause briefly, then speak. Familiar commands work locally;
questions use the Claude key from Services. Hearing has the wake switch,
confidence, phrase and speech-model pickers, and the speech gate. Speech
capture ends after 0.8 seconds below the gate or eight seconds total. Audio
and text are never saved. The existing short Shazam ring is unchanged.

## Install and enable

Run `bash pi/install-voice.sh` in `/home/pi/wall-codex`. This builds
whisper.cpp revision `1d549b3cecc2d98d76d4ddc2edca0d1512f5d7a0` with two
build jobs, static libraries, no Metal or OpenMP. It installs openWakeWord
revision `368c03716d1e92591906a84949bc477f3a834455` with its ONNX runtime
and feature dependencies, and downloads the official v0.5.1 Jarvis feature
models plus multilingual Whisper tiny/base. Models live in this checkout's
ignored `models/voice`; dependencies stay in its own venv. Nothing touches
the renderer, Claude tree or HomeKit pairing.

Set `[features] wake = true` and `horizon = true` in the Pi-owned config;
in Hearing turn Wake on. The shipped phrase choice is 0, Hey Jarvis. Choice
1 loads `models/voice/hey_wall.onnx`. **The custom Hey wall model has not
been trained or accepted.** Selecting it without its file reports unavailable
and does not silently select another phrase. Use the official
[custom training notebook](https://github.com/dscripka/openWakeWord/blob/main/notebooks/automatic_model_training.ipynb)
for synthetic training, export ONNX, then verify it against positive and
negative room clips before selecting it. Jarvis is the brief's fallback.
The pretrained wake models have a CC BY-NC-SA 4.0 license; openWakeWord code
is Apache 2.0 and whisper.cpp is MIT. Preserve their source and licenses.

The numeric tuning protocol remains compatible with the existing app.
The Hearing page shows named menus: `wake_word` 0 Jarvis / 1 wall;
`speech_model` 0 tiny / 1 base. `wake_threshold` starts at 0.5;
`speech_gate` starts at -45 dB. A noisy room may need a higher speech gate.
All choices are stored on the wall so a second phone sees them.

## Commands

Off, on, art, disc, ambient, clock, lyrics, nine, video off, brighter,
dimmer, louder, quieter, what is this, timer N minutes, and listen.
“Teach this, it is X by Y” arms the next twenty continuous audible seconds
under that name; play the song after speaking. The request expires after
ninety seconds. Teaching must be enabled; only fingerprints are retained.
Unknown phrases become an Ask request. Fuzzy matching applies only to
complete short phrases, so a question containing “off” cannot turn off
the wall. Any phone control change cancels a pending speech result.

## Latency and verification

The microphone hands off 100 ms chunks to a four-entry queue. ONNX consumes
80 ms frames on one thread. The Pi averaged 7.5 ms of inference per 100 ms
of synthetic audio. A synthesized Hey Jarvis scored 0.999. The exact local
transcriber produced “Set a timer for 5 minutes.” in 1.69 seconds, using
stdin and stdout, no audio file. Whisper uses two threads and a bounded
context sized for the clip, at least 256 audio tokens. Processes are killed
after 2.9 seconds; slow speech or Base can therefore produce the quiet
failure animation. The 3-second bound is enforced, but recognition accuracy
and timing for all eight-second utterances are not yet accepted.

Wake-to-first-frame is designed for the next 100 ms capture plus one
render frame, below 300 ms once models are loaded. The first load is shown
as Loading on the phone and does not claim to listen yet. No room-recorded
custom Hey wall test has been performed. The synthesized fixture is not a
substitute for that test. The iPhone page builds for Simulator; physical
installation still needs the separate Codex App Group provisioned in Xcode.

Offline tests cover transcriber-like misspellings, word-number timers,
question safety, silence and eight-second capture, actual control actions,
late-result cancellation, and failure restoration. Run
`.venv/bin/python -m pytest brain/tests -q`. `/services.voice` reports the
state, selected phrase, custom-model availability, last transcription time
and a quiet error without a transcript. Use `/health` for wall load.
