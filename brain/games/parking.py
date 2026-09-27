"""A parked game: still held by the GameHost while the wall shows another face.

The phone keeps polling a parked game (the game screen every second, the
games hub every three) and every poll runs the game's state(). A game that
timed itself on wall-clock time therefore kept playing while it was parked:
the phone had disabled the board, the host ignored the wall's ears, and the
round ran out and was recorded as a loss. These helpers let a timed game see
that it is parked and stop its own clock.
"""
from __future__ import annotations

# The longest silence between two readings that still counts as time on the
# wall. The render loop draws a shown game about 30 times a second
# (brain/main.py, the "game" face), so a longer silence means the wall was not
# showing it: another face, the wall off, or a spoken answer drawn over it.
GAP_S = 1.5


def held(game) -> bool:
    """True while `game` is the one a real host holds, the only case in which
    the wall's render loop draws it. False while the game is still being set
    up and for a game with no host, as in most tests."""
    host = getattr(game, "host", None)
    return getattr(host, "ctrl", None) is not None and getattr(host, "game", None) is game


def parked(game) -> bool:
    """True while `game` is the host's game but the wall shows something else.

    The host calls into the game while holding its own lock, and ctrl.get()
    only takes the controller's lock for a copy, which is the
    host-then-controller order GameHost.status() already uses."""
    if not held(game):
        return False
    return game.host.ctrl.get().get("mode") != "game"


class ParkedClock:
    """A game's own time: the raw clock with the parked stretches taken out.

    Read it with the raw clock value and whether the game is parked now. It
    stands still while the game is parked and carries on from the same value
    once the game is back.

    A park is dated from the last reading taken while the game was on the
    wall, not from the first reading that noticed it. The render loop reads
    a game many times a second while it is shown, so that is within a frame
    of the switch, and a park that some reading notices costs no time.
    GameHost.resume() takes one reading before it brings a game back for
    exactly that reason.

    A park can also end with no reading at all: a double knock or a whistle
    turns the wall off and back on, the phone or a timer sets the mode, and
    none of those go through the host. The first reading after such a park
    is on the wall, so nothing says the game was away except the silence
    before it. For a hosted game (`hosted`), a silence longer than GAP_S is
    taken as parked time too, since the render loop would have read a game
    that was being shown. A game with no host keeps every second, so a test
    can move a fake clock on without a render loop."""

    def __init__(self):
        self.lost = 0.0          # parked seconds already taken out
        self.since = None        # raw time the current park began
        self.seen = None         # raw time of the last reading on the wall

    def now(self, raw: float, is_parked: bool, hosted: bool = False) -> float:
        if is_parked:
            if self.since is None:
                self.since = raw if self.seen is None else min(raw, self.seen)
            return self.since - self.lost
        if self.since is not None:
            self.lost += max(0.0, raw - self.since)
            self.since = None
        elif hosted and self.seen is not None and raw - self.seen > GAP_S:
            # An unread park that ended some other way than resume(): date it
            # from the last reading on the wall, as a noticed park is.
            self.lost += raw - self.seen
        self.seen = raw
        return raw - self.lost

    def read(self, game, raw: float) -> float:
        """now() for `game`, with parked and hosted worked out from it."""
        return self.now(raw, parked(game), hosted=held(game))
