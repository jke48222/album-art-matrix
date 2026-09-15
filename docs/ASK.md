# Ask the wall, and leave it a note

The wall answers questions and takes notes two ways: through its own ears
(say the wake word, then talk), and through Siri Shortcuts on the phone,
the Watch, or a HomePod, which do the listening and hand the wall the words.
Both end on the panel; the Shortcut path can also speak the answer back.

## From the wall's own ears

Say the wake word ("hey Jarvis" until the "hey wall" model is trained; the
Voice knobs on the phone's Hearing page show the live score). The picture
folds to a line while the wall listens, a bead runs along it while it
thinks, and the answer opens from the line.

Things it does itself, with no cloud: off, on, art, disc, ambient, clock,
lyrics, nine, stop the video, brighter, dimmer, "what is this", "listen
again", "timer ten minutes", "show me the Blond cover", "play the Gameboy
video", "teach this, it is Tower of Roses by MALI", "what song goes
[the words]", "note: back at six". Everything else is a question for
Claude, which needs the key from the next section.

## The Claude key

Console > Services > Claude on the phone. Paste an Anthropic API key
(`sk-ant-...`). It lives on the wall in `services.json`, never in the app
or in git. Answers cost about a cent each with Claude Opus 5; the Services
page shows the running total.

## The "Ask the wall" Shortcut

Build it once in the Shortcuts app (a Shortcut file cannot be shared
unsigned):

1. New Shortcut, named **Ask the wall**.
2. Add **Dictate Text**. Stop listening: after pause.
3. Add **Get Contents of URL**:
   - URL `http://album-matrix.local:8788/ask`
   - Method POST, Request Body JSON, one field: `text` = Dictated Text,
     and a second field `reply` = `text` if you want Siri to speak the
     answer and keep the panel as it is; leave `reply` out to have the
     answer drawn on the panel as well.
4. Add **Get Dictionary Value** for key `answer` from Contents of URL.
5. Add **Speak Text** with that value (or Show Result).

Then: "Hey Siri, ask the wall" from the phone, the Watch, or a HomePod
signed into the same account, followed by the question when it prompts.

## The "Tell the wall" Shortcut

Same shape, for a note on the panel:

1. New Shortcut, named **Tell the wall**.
2. **Dictate Text**.
3. **Get Contents of URL**: `http://album-matrix.local:8788/note`, POST,
   JSON body `text` = Dictated Text, `minutes` = 30.

"Hey Siri, tell the wall" and then the note. The panel runs it across for
half an hour, then goes back to whatever it was showing.

## From a terminal

    curl -s -X POST http://album-matrix.local:8788/ask -H 'Content-Type: application/json' \
      -d '{"text": "what played during dinner?"}'
    curl -s -X POST http://album-matrix.local:8788/note -H 'Content-Type: application/json' \
      -d '{"text": "back at six", "minutes": 20}'
    curl -s http://album-matrix.local:8788/voice           # the wake word's state and the last thing heard
    curl -s -X POST http://album-matrix.local:8788/voice/say -H 'Content-Type: application/json' \
      -d '{"text": "turn the lights on"}'                  # the words, without the microphone
