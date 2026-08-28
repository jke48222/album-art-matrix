"""Dev sink for the Mac: writes preview_out/panel.png — the processed frame
scaled up with hard pixel edges and a faint grid, to judge 64 px legibility
before any hardware exists."""
import os

from PIL import Image, ImageDraw

from . import FrameSink


class MacPreviewSink(FrameSink):
    def __init__(self, out_dir: str = "preview_out", scale: int = 8):
        self.out_dir = out_dir
        self.scale = scale
        os.makedirs(out_dir, exist_ok=True)

    def show(self, rgb888: bytes, pre_wb_img=None):
        if pre_wb_img is None:
            side = int((len(rgb888) // 3) ** 0.5)
            img = Image.frombytes("RGB", (side, side), rgb888)
        else:
            img = pre_wb_img
        w, h = img.size
        big = img.resize((w * self.scale, h * self.scale), Image.NEAREST)
        draw = ImageDraw.Draw(big)
        for x in range(0, big.width + 1, self.scale):
            draw.line([(x, 0), (x, big.height)], fill=(12, 12, 12))
        for y in range(0, big.height + 1, self.scale):
            draw.line([(0, y), (big.width, y)], fill=(12, 12, 12))
        tmp = os.path.join(self.out_dir, ".panel.tmp.png")
        out = os.path.join(self.out_dir, "panel.png")
        big.save(tmp)
        os.replace(tmp, out)

