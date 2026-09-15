#!/usr/bin/env python3
"""Sound design for the Record sting: four generated cues placed on the
animation's own timeline, mixed, limited, and married to a video.

    python3 tessera/Tools/record_sound.py <cues dir> <video.mp4> <out.mp4> [--lock 1.55] [--word 1.6]

Timeline (seconds): the riser swells from 0.0 and stops at the moment the
disc locks; the click cascade runs under the build from 0.2; the lock thud
lands at --lock; the shimmer opens at --word as the name appears. Silence
after, and a tail to the end of the picture. The defaults are the vector
sting's timing; a generative re-render lands its beats elsewhere, so pass
the times measured from that render.
"""
import os
import subprocess
import sys

def cues_for(lock, word):
    """name, start s, max length s, level dBFS peak after normalising, fade-out s"""
    return [
        ("riser", 0.00, lock, -9.0, 0.06),
        ("clicks", 0.20, max(0.4, lock - 0.3), -14.0, 0.15),
        ("lock", lock, 1.20, -4.0, 0.40),
        ("shimmer", word, 1.40, -13.0, 0.50),
    ]


def peak_db(path):
    """The cue's peak level, so every generated cue can be brought to the
    same reference before the creative balance is applied."""
    out = subprocess.run(["ffmpeg", "-v", "info", "-i", path, "-af", "volumedetect", "-f", "null", "-"],
                         capture_output=True, text=True).stderr
    for line in out.splitlines():
        if "max_volume" in line:
            return float(line.split("max_volume:")[1].split("dB")[0])
    return 0.0


def main():
    cues, video, out = sys.argv[1:4]
    lock = float(sys.argv[sys.argv.index("--lock") + 1]) if "--lock" in sys.argv else 1.55
    word = float(sys.argv[sys.argv.index("--word") + 1]) if "--word" in sys.argv else 1.60
    inputs, chains, mixed = [], [], []
    for i, (name, start, length, level, fade) in enumerate(cues_for(lock, word)):
        path = os.path.join(cues, name + ".wav")
        if not os.path.exists(path):
            print("missing cue", name)
            continue
        gain = level - peak_db(path)
        inputs += ["-i", path]
        n = len(mixed)
        chains.append(f"[{n + 1}:a]aformat=sample_rates=48000:channel_layouts=stereo,"
                      f"atrim=0:{length},afade=t=out:st={max(0, length - fade)}:d={fade},"
                      f"volume={gain}dB,adelay={int(start * 1000)}|{int(start * 1000)}[c{n}]")
        mixed.append(f"[c{n}]")
    graph = ";".join(chains) + ";" + "".join(mixed) + f"amix=inputs={len(mixed)}:normalize=0:dropout_transition=0," \
            "alimiter=limit=0.89:attack=3:release=60,apad,aresample=48000[a]"   # apad: silence to the end of the picture
    cmd = ["ffmpeg", "-v", "error", "-y", "-i", video] + inputs + [
        "-filter_complex", graph, "-map", "0:v", "-map", "[a]", "-c:v", "copy",
        "-c:a", "aac", "-b:a", "256k", "-shortest", out]
    subprocess.run(cmd, check=True)
    print("wrote", out)


if __name__ == "__main__":
    main()
