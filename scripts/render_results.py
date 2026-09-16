"""Render certain and ambiguous catalogue results at both wall sizes."""
from pathlib import Path

from PIL import Image

from brain.art.result import ResultFace
from brain.sinks.mac_preview import MacPreviewSink


def main():
    root = Path("docs/verification/results")
    root.mkdir(parents=True, exist_ok=True)
    items = [{"title": "Tower of Roses", "artist": "MALI",
              "image": Image.new("RGB", (500, 500), (185, 72, 40))},
             {"title": "Tower Song", "artist": "Another Artist",
              "image": Image.new("RGB", (500, 500), (35, 74, 138))}]
    for size in (64, 192):
        for name, choices in (("certain", items[:1]), ("uncertain", items)):
            face = ResultFace(size, choices)
            frames = [Image.fromarray(face.frame_at(t)) for t in (0, 2, 4, 6)]
            strip = Image.new("RGB", (size * 4, size))
            for index, frame in enumerate(frames):
                strip.paste(frame, (index * size, 0))
                sink = MacPreviewSink(str(root / f"{name}-{size}-{index}"),
                                      scale=8 if size == 64 else 4)
                sink.show(frame.tobytes(), pre_wb_img=frame)
            strip.save(root / f"{name}-{size}.png")
    print("[result] certain and ambiguous faces rendered at 64 and 192")


if __name__ == "__main__":
    main()
