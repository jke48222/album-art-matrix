# The voice

The wall listens for a wake word on its own microphone. Say it and the
picture folds to a line while it listens; a command is done on the wall, a
question goes to Claude and comes back as words on the panel. The code is in
`brain/voice/`.

## The wake word

Out of the box it is **Hey Jarvis**. Change it on the phone: Settings, What
the wall can do, Voice, Wake word. Tap a word and the wall is listening for
it a moment later; the choice survives restarts.

| Word | Kind | Good to know |
| --- | --- | --- |
| Hey Jarvis | built in | the first one |
| Hey Mycroft | built in | |
| Hey Marvin | built in | |
| Alexa | built in | an Echo in the room answers to it too |
| A phrase of your own | taught | any two or three words, said to the wall six times |

The built-in words are openWakeWord's pretrained heads, trained on thousands
of synthetic voices with noise and echo mixed in. A phrase of your own has no
head: the wall keeps your takes as sequences of the same speech embeddings
and matches the live sound against them (`brain/voice/enroll.py`).

### Teaching your own

On the Voice page, Make your own. Type the phrase, press Start, and stand
where you usually talk to the wall.

1. Say the phrase, then pause. Each take lights a dot on the wall and on the
   phone. A take too short or too long is refused with a word why, and the
   line flickers red.
2. After six takes, talk normally for ten seconds about anything else. This
   is how it learns what is not the phrase.
3. It learns in a second or two, switches to the new word, and says how well
   it stands apart from ordinary talk: good, fair or poor.

Anyone else who will use it can say a take or two. Nobody speaking for a
minute and a half stops the teaching by itself, so the wall is never left
waiting. Teaching the same phrase again replaces it; Forget removes a word
that is not in use.

### Sensitivity

Each word keeps its own, on the Voice page. The live meter above the slider
shows how sure the wall is right now, its recent peak behind that, and a
white mark for the line it has to pass; say the word and watch it. Further
left wakes more easily and by mistake more often. Default puts it back:
0.5 for a built-in word, 0.75 for your own, whose score runs on its own
scale. The wake threshold knob on the tuning page is the same setting for
the word in use.

## How well a phrase of your own works

Measured on 2026-09-15 with the Pi's own speech model, on synthetic voices
from macOS text to speech: "hey wall" taught by six voices, then said by
those six at other speeds and by thirteen voices it never heard, eighteen
other phrases in six voices each, and 3.6 minutes of household talk. At the
default of 0.75:

| Room | Same voices heard | New voices heard | Other phrases that woke it | False wakes in the talk |
| --- | --- | --- | --- | --- |
| Quiet | 100% | 100% | 6%, all of them "hey all" | none |
| Echoing, noise 15 dB under the voice | 100% | 97% | 21% | none |
| Taught there, used somewhere noisier | 92% | 90% | 25% | none |

In the echoing room every phrase that woke it began with "hey" ("hey google",
"hey paul", "hey wallace") or ended in "wall". The built-in Hey Jarvis in the
same room heard four takes in six, woke for 1% of other phrases, and woke
about once every four minutes of talk.

So a phrase of your own is dependable in an ordinary room and rarely wakes
during conversation. In a loud room, phrases that start the same way can
wake it. Choose one that does not begin like things said in the house, or
use a built-in word where the room is loud.

Two things made the difference. The room's own sound is taken out before
matching: without it, the echoing room woke on 73% of other phrases and
about once a minute of talk. And the score is set from your takes and your
ten seconds of talk, not from a fixed number.

## Testing without a microphone

| Route | What it does |
| --- | --- |
| `GET /voice` | the wake word, the choices, teaching, the last thing heard |
| `GET /voice/meter` | the live score, peak, threshold and room level; quick, for the meter |
| `POST /voice/wakeword {"name": "hey_mycroft"}` | switch words |
| `POST /voice/wakeword {"threshold": 0.6}` | the sensitivity of the word in use |
| `POST /voice/wakeword/forget {"name": "own:hey-wall"}` | forget a phrase of your own |
| `POST /voice/enroll {"phrase": "hey wall"}` | start teaching; `POST /voice/enroll/cancel` stops |
| `POST /voice/wake` | listen now, as if the word was said |
| `POST /voice/say {"text": "show the clock"}` | words as if spoken |

## Where things are kept

- `~/.config/album-art-matrix/wake.json`: the word in use and each word's sensitivity.
- `~/.config/album-art-matrix/wakewords/<phrase>.npz` and `.json`: phrases of your own.

Teaching borrows the speech model the wall already has loaded, so it adds no
memory on the Pi's 1 GB.
