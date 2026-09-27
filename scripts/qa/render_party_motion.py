#!/usr/bin/env python3
"""Show complete production question text over time at the true64-pixel size."""
from pathlib import Path
import sys
from PIL import Image
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT))
from party_games_fixtures import build

def main():
    output=ROOT/'qa/batch-12/puzzles';output.mkdir(parents=True,exist_ok=True)
    for name in ('twentyq','quiz'):
        game=build(name,'playing');images=[];now=[100.0]
        game._clock=lambda:now[0]
        if name=='quiz':game.t_q=100.0
        for frame in range(76):
            now[0]=100+frame*.25
            image=Image.fromarray(game.frame_at(64,frame*.25)).resize((384,384),Image.Resampling.NEAREST)
            images.append(image)
        images[0].save(output/f'{name}-question-motion.gif',save_all=True,append_images=images[1:],duration=250,loop=0,disposal=2)
if __name__=='__main__':main()
