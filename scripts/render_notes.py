"""Inspect the existing across ticker used by notes at both wall sizes."""
from pathlib import Path
from PIL import Image
from brain.art.text_modes import Ticker
from brain.sinks.mac_preview import MacPreviewSink
root=Path('docs/verification/notes')
root.mkdir(parents=True, exist_ok=True)
for size in (64,192):
    (root/f'config-{size}.toml').write_text(f'[panel]\nwidth={size}\nheight={size}\n[wall]\ntile=64\ncols={size//64}\nrows={size//64}\n')
    face=Ticker(size,'Back at six', loop=True)
    frames=[]
    for i,t in enumerate((1,3,5,7)):
        frame=face.frame_at(t)
        if not isinstance(frame,Image.Image): frame=Image.fromarray(frame)
        frames.append(frame)
        sink=MacPreviewSink(str(root/f'{size}-{i}'),scale=8 if size==64 else 4)
        sink.show(frame.tobytes(),pre_wb_img=frame)
    strip=Image.new('RGB',(size*4,size))
    for i,f in enumerate(frames): strip.paste(f,(i*size,0))
    strip.save(root/f'note-{size}.png')
