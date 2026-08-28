#!/usr/bin/env python3
"""Generate tessera/Tessera/PixelFont.swift from brain/art/pixelfont.py.

The wall and the phone must draw a letter identically, so the font has one
source and the Swift copy is generated from it rather than transcribed. Run
this after changing the Python font.

    .venv/bin/python tessera/Tools/gen_pixelfont.py
"""
import io
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, REPO)

from brain.art.pixelfont import FONT, ALIASES  # noqa: E402

OUT = os.path.join(REPO, "tessera", "Tessera", "PixelFont.swift")

HEADER = '''// The wall's handwriting, in Swift.
//
// GENERATED from brain/art/pixelfont.py by tessera/Tools/gen_pixelfont.py.
// Do not hand-edit: the whole point is that the phone and the wall render a
// letter identically. Regenerate when the Python font changes.
//
// Rows are 5-bit masks, bit 4 is the leftmost column. Uppercase only; an
// unknown character renders as a hollow box so a typo is visible instead of
// silently vanishing.

import Foundation

enum PixelFont {
    static let width = 5
    static let height = 7
    /// One blank column between glyphs.
    static let advance = 6

    static let box: [UInt8] = [0x1F, 0x11, 0x11, 0x11, 0x11, 0x11, 0x1F]

    static let glyphs: [Character: [UInt8]] = [
'''

FOOTER = '''    ]

    /// "<3" is how a heart gets typed.
    static func normalize(_ text: String) -> String {
        var out = ""
        var skip = false
        let chars = Array(text.uppercased())
        for (i, ch) in chars.enumerated() {
            if skip { skip = false; continue }
            if ch == "<", i + 1 < chars.count, chars[i + 1] == "3" {
                out.append("\\u{2665}")
                skip = true
            } else if let alias = aliases[ch] {
                out.append(alias)
            } else {
                out.append(ch)
            }
        }
        return out
    }

    private static let aliases: [Character: Character] = [%(aliases)s]

    static func glyph(_ ch: Character) -> [UInt8] { glyphs[ch] ?? box }

    /// Total width including the one-column gaps.
    static func textWidth(_ text: String, scale: Int = 1) -> Int {
        let n = text.count
        return (n * width + max(0, n - 1)) * scale
    }

    /// Greedy wrap to a pixel width, so a long line becomes several.
    static func wrap(_ text: String, maxWidth: Int, scale: Int) -> [String] {
        var lines: [String] = []
        var line = ""
        for word in text.split(separator: " ", omittingEmptySubsequences: false) {
            let candidate = line.isEmpty ? String(word) : line + " " + word
            if textWidth(candidate, scale: scale) <= maxWidth || line.isEmpty {
                line = candidate
            } else {
                lines.append(line)
                line = String(word)
            }
        }
        if !line.isEmpty { lines.append(line) }
        return lines
    }
}
'''


def swift_key(ch: str) -> str:
    if ch == '"':
        return '"\\""'
    if ch == "\\":
        return '"\\\\"'
    return '"%s"' % ch


def main() -> None:
    rows = []
    for ch, mask in FONT.items():
        if ch == "_BOX":
            continue
        vals = ", ".join("0x%02X" % r for r in mask)
        rows.append("        %s: [%s]," % (swift_key(ch), vals))

    # "<" is handled by the "<3" rule in normalize, not as a plain alias
    alias_pairs = ", ".join(
        '"%s": "\\u{2665}"' % k for k in ALIASES if k != "<"
    )

    src = HEADER + "\n".join(rows) + "\n" + (FOOTER % {"aliases": alias_pairs})
    io.open(OUT, "w", encoding="utf8").write(src)
    print("wrote %s (%d glyphs)" % (os.path.relpath(OUT, REPO), len(FONT) - 1))


if __name__ == "__main__":
    main()
