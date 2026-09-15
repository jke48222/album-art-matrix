"""The wall's own ears for speech: a wake word, a listener, a transcriber,
a small grammar of commands, and Claude for everything else.

    wake.py      "hey wall" (or the pretrained "hey jarvis" until the custom
                 model is trained), on the ear's 16 kHz stream, on the Pi
    listen.py    speech to text on the Pi (faster-whisper, tiny or base)
    commands.py  the phrases the wall understands without any cloud
    voice.py     the state machine: idle, listening, thinking, answering;
                 and the Horizon face's frames while it happens

The ear feeds the same 100 ms chunks it keeps for Shazam into `Voice.feed`;
nothing new touches the microphone. Audio after the wake word lives in
memory for the length of one request and is gone.
"""
from .voice import Voice   # noqa: F401
