"""What the wall understands without a cloud.

A transcript comes in; a Command goes out, or None, which means the words
are a question for Claude. Matching is forgiving: the wake phrase and
politeness are stripped, punctuation is dropped, and a fixed phrase counts
when it is close enough for a transcriber that heard "lyrics" as "lirics".
The parametric ones (a timer, a search, a song to teach) are patterns.

Every phrase here is also a thing the phone can do, so a command is never
the only way; it is the way that needs no hands.
"""
from __future__ import annotations

import difflib
import re

WAKE_PREFIXES = ("hey wall", "hey jarvis", "jarvis", "wall", "okay wall", "ok wall", "hey")
FILLERS = ("please", "could you", "can you", "would you", "now", "for me")
FUZZ = 0.80                         # how close a fixed phrase has to be

NUMBERS = {"one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
           "eight": 8, "nine": 9, "ten": 10, "fifteen": 15, "twenty": 20, "thirty": 30,
           "forty": 40, "forty five": 45, "sixty": 60, "an hour": 60, "one hour": 60,
           "half an hour": 30, "a minute": 1, "a": 1, "half": 30}

# name -> the phrases that mean it
FIXED = {
    "off": ["turn off", "off", "go dark", "lights out", "turn the wall off", "wall off",
            "go to sleep", "sleep", "good night", "goodnight", "switch off"],
    "on": ["turn on", "on", "wake up", "turn the wall on", "wall on", "come back", "lights on",
           "switch on"],
    "art": ["art", "the art", "sleeve", "the sleeve", "album art", "show the art", "cover",
            "show the cover", "back to the art", "go back"],
    "cd": ["disc", "the disc", "record", "spin", "spin the record", "the record", "vinyl"],
    "ambient": ["ambient", "light", "lights", "mood light", "colours", "colors", "glow"],
    "clock": ["clock", "the clock", "the time", "what time is it", "show the time", "time"],
    "lyrics": ["lyrics", "the lyrics", "words", "the words", "show the lyrics", "sing"],
    "nine": ["nine", "the nine", "grid", "the grid", "recent", "the last nine"],
    "video_off": ["stop the video", "video off", "stop video", "stop"],
    "brighter": ["brighter", "more light", "louder", "brighten", "turn it up", "up"],
    "dimmer": ["dimmer", "less light", "quieter", "dim", "turn it down", "down", "softer"],
    "whatis": ["what is this", "what's this", "what is playing", "what's playing",
               "what song is this", "who is this", "what is that", "name this", "what am i hearing",
               "what is this song", "what song is playing"],
    "listen": ["listen", "listen again", "what do you hear", "have a listen", "try again"],
    "cancel": ["cancel", "never mind", "nevermind", "nothing", "forget it"],
}


class Command:
    def __init__(self, name: str, **args):
        self.name = name
        self.args = args

    def __repr__(self):
        return f"Command({self.name}, {self.args})" if self.args else f"Command({self.name})"

    def __eq__(self, other):
        return isinstance(other, Command) and other.name == self.name and other.args == self.args


def clean(text: str) -> str:
    t = (text or "").lower().strip()
    t = re.sub(r"[^\w\s']", " ", t)
    t = re.sub(r"\s+", " ", t).strip()
    for p in sorted(WAKE_PREFIXES, key=len, reverse=True):
        if t.startswith(p + " "):
            t = t[len(p) + 1:]
            break
        if t == p:
            return ""
    for f in FILLERS:
        t = re.sub(rf"\b{f}\b", " ", t)
    t = re.sub(r"\s+", " ", t).strip()
    return t


def _minutes(words: str) -> int | None:
    w = words.strip()
    if w.isdigit():
        return int(w)
    if w in NUMBERS:
        return NUMBERS[w]
    m = re.match(r"(\w+)\s+(\w+)", w)
    if m and m.group(1) in NUMBERS and m.group(2) in NUMBERS:
        return NUMBERS[m.group(1)] + NUMBERS[m.group(2)]
    return None


PATTERNS = [
    (re.compile(r"^(?:set (?:a )?)?timer(?: for)? (.+?) ?(?:minutes?|mins?|min)?$"), "timer"),
    (re.compile(r"^(.+?) minutes? timer$"), "timer"),
    (re.compile(r"^teach (?:this|that|it)[, ]*(?:it is|it's|this is|that is|its) (.+?) by (.+)$"), "teach"),
    (re.compile(r"^(?:this|that) is (.+?) by (.+?)(?:,? (?:learn|teach) (?:it|this))?$"), "teach_maybe"),
    (re.compile(r"^(?:what|which) song (?:goes|has the (?:words|lyrics?)|is it that goes)[, ]*(.+)$"), "earworm"),
    (re.compile(r"^(?:find|name) the song (?:that goes|with the words|with)[, ]*(.+)$"), "earworm"),
    (re.compile(r"^show (?:me )?(?:the )?(.+?)(?: (?:cover|sleeve|album|art))?$"), "show"),
    (re.compile(r"^play (?:me )?(?:the )?(.+?)(?: video)?$"), "play"),
    (re.compile(r"^(?:create|draw|make|imagine|paint) (?:me )?(?:a |an |the )?(.+)$"), "imagine"),
    (re.compile(r"^(?:leave a note|note|write)[:,]? (.+)$"), "note"),
]


def match(text: str) -> Command | None:
    """A Command for words the wall handles itself, or None for Claude."""
    t = clean(text)
    if not t:
        return Command("cancel")
    # a face by name, said plainly or as "show (me) (the) ...": exactly, first
    bare = re.sub(r"^(?:show|put up|give me|switch to|go to) (?:me )?(?:the )?", "", t)
    for name, phrases in FIXED.items():
        if t == name or t in phrases or bare == name or bare in phrases:
            return Command(name)
    for rx, name in PATTERNS:
        m = rx.match(t)
        if not m:
            continue
        if name == "timer":
            n = _minutes(m.group(1))
            if n:
                return Command("timer", minutes=max(1, min(180, n)))
            continue
        if name in ("teach", "teach_maybe"):
            title, artist = m.group(1).strip(), m.group(2).strip()
            if name == "teach_maybe" and not t.endswith(("learn it", "teach it", "learn this", "teach this")):
                continue
            return Command("teach", title=title, artist=artist)
        if name == "earworm":
            return Command("earworm", words=m.group(1).strip())
        if name == "show":
            return Command("show", query=m.group(1).strip())
        if name == "play":
            q = m.group(1).strip()
            if q in ("", "it", "again"):
                continue
            return Command("play", query=q)
        if name == "imagine":
            return Command("imagine", prompt=m.group(1).strip())
        if name == "note":
            return Command("note", text=m.group(1).strip())
    best, best_r = None, 0.0
    for name, phrases in FIXED.items():
        for p in phrases:
            r = difflib.SequenceMatcher(None, t, p).ratio()
            if r > best_r:
                best, best_r = name, r
    if best is not None and best_r >= FUZZ:
        return Command(best)
    return None
