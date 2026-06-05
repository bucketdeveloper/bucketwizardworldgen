"""Preview of elevated terrain (plateaus / mesas) using the real sprites and the
same isometric + column-stacking math the Godot renderer will use.

Heightmap rules previewed here:
  - water is always at the lowest level (height 0),
  - grass and dirt sit at height 0 OR rise in clumps (plateaus) up to MAX_H,
  - each cell draws a stack of cubes 0..h; upper cubes' walls form the cliff
    faces and hide the tops of the cubes beneath them.
"""
import random
import numpy as np
from scipy import ndimage
from PIL import Image

MAP = 64                # preview map size (cells per side)
STEP = 8                # vertical pixels per elevation level (the block/wall height)
MAX_H = 3
SHEET = "/sessions/festive-kind-cori/mnt/bucketwizardworldgen/assets/spritesheet.png"

GRASS, DIRT, WATER = 0, 1, 2
GRASS_T = [(0, 2), (1, 2), (2, 2), (7, 2), (8, 2)]
DIRT_T = [(0, 0), (1, 0), (2, 0), (3, 0), (0, 1)]
WATER_T = [(0, 10), (1, 10), (2, 10), (10, 10)]

sheet = Image.open(SHEET).convert("RGBA")


def spr(col, row):
    return sheet.crop((col * 32, row * 32, col * 32 + 32, row * 32 + 32))


def blob_noise(seed, sigma):
    rng = np.random.default_rng(seed)
    n = ndimage.gaussian_filter(rng.standard_normal((MAP, MAP)), sigma=sigma, mode="wrap")
    n -= n.mean(); n /= n.std()
    return n


def generate(seed):
    random.seed(seed)
    terr = np.full((MAP, MAP), GRASS)
    base = blob_noise(seed, 5.0)
    terr[base < -0.4] = DIRT
    # a lake / water patch (lowest level)
    water = blob_noise(seed + 99, 4.0)
    terr[water > 1.1] = WATER

    # elevation: clumps where a separate noise is high, never on water
    elev_noise = blob_noise(seed + 7, 3.5)
    height = np.zeros((MAP, MAP), int)
    height[elev_noise > 0.6] = 1
    height[elev_noise > 1.1] = 2
    height[elev_noise > 1.5] = 3
    height[terr == WATER] = 0
    return terr, height


def tile_for(terr):
    pool = WATER_T if terr == WATER else (DIRT_T if terr == DIRT else GRASS_T)
    return spr(*random.choice(pool))


# water shoreline auto-tiling -------------------------------------------------
# flags: TL=1 (x-1,y)  TR=2 (x,y-1)  BR=4 (x+1,y)  BL=8 (x,y+1)
WATER_EDGE = {
    0: 0,    # open water (all sides water)
    2: 1,    # land on TR
    1: 2,    # land on TL
    4: 3,    # land on BR
    8: 4,    # land on BL
    3: 5,    # TL+TR
    12: 6,   # BL+BR
    9: 7,    # TL+BL
    6: 8,    # TR+BR
    15: 9,   # all four
}


def is_land(terrgrid, x, y):
    if x < 0 or x >= MAP or y < 0 or y >= MAP:
        return False
    return terrgrid[y][x] != WATER


def water_tile(terrgrid, x, y):
    f = 0
    if is_land(terrgrid, x - 1, y): f |= 1
    if is_land(terrgrid, x, y - 1): f |= 2
    if is_land(terrgrid, x + 1, y): f |= 4
    if is_land(terrgrid, x, y + 1): f |= 8
    if f == 0:
        col = 10 if random.random() < 0.25 else 0   # some rough open water
    else:
        col = WATER_EDGE.get(f, 9)                    # fallback: shore all sides
    return spr(col, 10)


def render(terr, height, path):
    W = (MAP + MAP) * 16 + 32
    H = (MAP + MAP) * 8 + MAX_H * STEP + 64
    cv = Image.new("RGBA", (W, H), (28, 30, 42, 255))
    ox = W // 2 - 16
    oy = 16 + MAX_H * STEP
    # draw back-to-front: increasing (x+y), then bottom-to-top within a column
    for s in range(2 * MAP - 1):
        for x in range(MAP):
            y = s - x
            if y < 0 or y >= MAP:
                continue
            h = int(height[y][x])
            px = ox + (x - y) * 16
            py = oy + (x + y) * 8
            for lvl in range(h + 1):
                if terr[y][x] == WATER:
                    sprite = water_tile(terr, x, y)
                else:
                    sprite = tile_for(terr[y][x])
                cv.alpha_composite(sprite, (px, py - lvl * STEP))
    cv.save(path)
    print("saved", path, cv.size)


if __name__ == "__main__":
    terr, height = generate(3)
    nz = int((height > 0).sum())
    print(f"raised cells: {nz}/{MAP*MAP} ({nz/(MAP*MAP):.0%}); "
          f"levels: " + ", ".join(f"h{l}={int((height==l).sum())}" for l in range(MAX_H + 1)))
    render(terr, height, "/sessions/festive-kind-cori/mnt/outputs/heightmap_preview.png")
