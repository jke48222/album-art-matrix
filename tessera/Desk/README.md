# Tessera on the desk

An Übersicht widget that keeps the wall in a corner of the Mac's desktop.

What it shows: the frame the wall is showing right now, drawn LED by LED the
way the phone app draws it (same core, halo and warm dimming as PanelCanvas
in FrameView.swift), the song under it with the record's own colour on the
progress line, "on your shelf" when the pressing is in your Discogs
collection, the faces as chips, and the wall's brightness on the scroll
wheel.

What it does: click a chip to change the face. Scroll over the panel to dim
or brighten the wall. Drag the grip at the top left to move it, drag the
corner at the bottom right to resize it, double-click either to put it back.

How it talks: straight to the brain's HTTP API from the desktop's web view,
no shell command and no helper. The frame once a second (`/frame.raw`), the
state every other second (`/state`), `POST /state` for mode and brightness.
It tries `album-matrix.local:8788` first and `localhost:8788` second, so the
same file works against the Pi and against a brain running on this Mac.
When the wall stops answering it keeps the last frame and says so, rather
than blanking the desktop.

## Install

Übersicht loads every folder in its widgets directory, so link this one in:

```
ln -s "$(pwd)/tessera.widget" "$HOME/Library/Application Support/Übersicht/widgets/tessera.widget"
```

Edits to `index.jsx` reload live. The fonts (Technor, Switzer, Martian Mono)
ship in `tessera.widget/fonts` under Fontshare's Free Font License, the same
files the app carries, so nothing needs installing.

## Why Übersicht and not a WidgetKit widget

A native macOS widget refreshes on a budget the system sets (tens of
reloads a day) and cannot draw a frame that changes every second. Übersicht
widgets are ordinary web pages on the desktop, so this one polls at the
rate the wall changes. If you want the native kind as well, the iPhone's own
Tessera widgets already appear in the Mac's widget gallery through
Continuity, with no build.
