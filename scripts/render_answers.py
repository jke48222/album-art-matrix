"""Render and record the answer layout at both real wall geometries."""
import json
from pathlib import Path

from PIL import Image

from brain.art.answer import Answer, PAGE_SECONDS
from brain.sinks.mac_preview import MacPreviewSink
from brain.wall import Wall


def main():
    root = Path('docs/verification/answers')
    root.mkdir(parents=True, exist_ok=True)
    report = {}
    cases = {'answer': 'The rain ends at six.', 'no-key': 'no key yet',
             'network': 'no answer right now', 'empty': 'Sorry, I could not answer.'}
    for size in (64, 192):
        wall = Wall(tile=64, cols=size//64, rows=size//64)
        (root / f'config-{size}.toml').write_text(f'[panel]\nwidth = {size}\nheight = {size}\n[wall]\ntile = 64\ncols = {wall.cols}\nrows = {wall.rows}\n[sink]\ntype = "preview"\n')
        for name, text in cases.items():
            face = Answer(size, text)
            strip = Image.new('RGB', (size * len(face.pages), size))
            for page in range(len(face.pages)):
                frame = Image.fromarray(face.frame_at(page * PAGE_SECONDS))
                strip.paste(frame, (page * size, 0))
                sink = MacPreviewSink(str(root / f'{name}-{size}-page-{page+1}'), scale=8 if size == 64 else 4)
                sink.show(frame.tobytes(), pre_wb_img=frame)
            strip.save(root / f'{name}-{size}.png')
            report[f'{name}-{size}'] = {'size': size, 'scale': face.scale, 'margin': face.margin,
                                      'rows': face.rows, 'pages': face.pages, 'seconds': face.duration}
    (root / 'layout.json').write_text(json.dumps(report, indent=2))
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
