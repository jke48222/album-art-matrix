"""Native strips and enlarged preview-sink frames of each Horizon state."""
from pathlib import Path
import numpy as np
from PIL import Image
from brain.art.horizon import Horizon
from brain.art.answer import Answer
from brain.sinks.mac_preview import MacPreviewSink

root = Path('docs/verification/horizon')
root.mkdir(parents=True, exist_ok=True)
for size in (64, 192):
    (root / f'config-{size}.toml').write_text(f'[panel]\nwidth = {size}\nheight = {size}\n[wall]\ntile = 64\ncols = {size//64}\nrows = {size//64}\n')
    now = [0.]
    art = np.zeros((size,size,3), dtype=np.uint8)
    art[:, :size//2] = (200, 80, 35)
    art[:, size//2:] = (30, 55, 90)
    face = Horizon(size, art.tobytes(), lambda: now[0])
    frames = []
    def take(name):
        f = Image.fromarray(face.frame_at(now[0]-face.changed))
        frames.append(f)
        sink = MacPreviewSink(str(root/f'{name}-{size}'), scale=8 if size == 64 else 4)
        sink.show(f.tobytes(), pre_wb_img=f)
    take('sleeve')
    now[0] = .125; take('collapse')
    now[0] = .25; take('line')
    now[0] = .4; face.level(-20); take('loud')
    now[0] = 1.2; take('release')
    face.think(); take('thinking-left')
    now[0] += .6; take('thinking-middle')
    face.open(); face.target(Answer(size, 'Yes').frame_at(0))
    now[0] += .2; take('opening')
    now[0] += .2; take('answer')
    face.fail(); take('missed')
    now[0] += .88; take('closing')
    now[0] += .08; take('closed')
    strip = Image.new('RGB', (size*len(frames),size))
    for i,f in enumerate(frames): strip.paste(f,(i*size,0))
    strip.save(root/f'sequence-{size}.png')
    # Two rows keep the native 192 layouts readable in a single view.
    sheet = Image.new('RGB',(size*6,size*2))
    for i,f in enumerate(frames): sheet.paste(f,((i%6)*size,(i//6)*size))
    sheet.save(root/f'contact-{size}.png')
print('[horizon] 12 states rendered at 64 and 192')
