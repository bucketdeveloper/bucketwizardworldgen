"""
Verification + preview for the Godot isometric map demo.

It mirrors the generation logic in scripts/main.gd so we can:
  1. confirm each carved river is a single 4-connected run of >= 20 water tiles,
  2. render the map with the REAL sprites using the same isometric math the
     Godot TileSet uses (top-face diamond 32x16, sprite drawn centred on the
     cell), so the tile alignment can be eyeballed before opening the editor.

This script is a test harness only; the game itself runs in Godot.
"""
import random
import numpy as np
from scipy import ndimage
from PIL import Image

MAP_W = MAP_H = 128
TILE_PX = 32
MIN_RIVER_LEN = 20
RIVER_COUNT = 3

GRASS, DIRT, WATER = 0, 1, 2

SHEET = "/sessions/festive-kind-cori/mnt/bucketwizardworldgen/assets/spritesheet.png"

GRASS_TILES = [(0, 2), (1, 2), (2, 2), (7, 2), (8, 2), (9, 2), (10, 2)]
DIRT_TILES = [(0, 0), (1, 0), (2, 0), (3, 0), (4, 0), (0, 1), (1, 1), (2, 1)]
WATER_TILES = [(0, 10), (1, 10), (2, 10), (3, 10), (4, 10), (10, 10)]


def in_bounds(x, y):
    return 0 <= x < MAP_W and 0 <= y < MAP_H


def carve_river(grid):
    """Exact port of _carve_river from main.gd."""
    flow_h = random.random() < 0.5
    dx = dy = 0
    if flow_h:
        l2r = random.random() < 0.5
        x = 0 if l2r else MAP_W - 1
        y = random.randrange(MAP_H)
        dx = 1 if l2r else -1
    else:
        t2b = random.random() < 0.5
        x = random.randrange(MAP_W)
        y = 0 if t2b else MAP_H - 1
        dy = 1 if t2b else -1

    placed, steps = 0, 0
    cells = []
    while steps < 4000 and placed < 500:
        steps += 1
        if in_bounds(x, y):
            grid[y][x] = WATER
            cells.append((x, y))
            placed += 1
            w = (x, y + 1) if flow_h else (x + 1, y)
            if in_bounds(*w):
                grid[w[1]][w[0]] = WATER
                cells.append(w)
        r = random.random()
        if flow_h:
            x += dx
            if r < 0.25:
                y += 1
            elif r < 0.5:
                y -= 1
        else:
            y += dy
            if r < 0.25:
                x += 1
            elif r < 0.5:
                x -= 1
        if not in_bounds(x, y):
            if placed >= max(MIN_RIVER_LEN, 40):
                break
            x = min(max(x, 0), MAP_W - 1)
            y = min(max(y, 0), MAP_H - 1)
    return cells


def smooth_noise(seed):
    """Blobby value noise standing in for Godot's FastNoiseLite (visual only)."""
    rng = np.random.default_rng(seed)
    n = rng.standard_normal((MAP_H, MAP_W))
    n = ndimage.gaussian_filter(n, sigma=6.0, mode="wrap")
    n -= n.mean()
    n /= n.std()
    return n


def generate():
    grid = [[GRASS] * MAP_W for _ in range(MAP_H)]
    noise = smooth_noise(random.randrange(1 << 30))
    for y in range(MAP_H):
        for x in range(MAP_W):
            grid[y][x] = DIRT if noise[y][x] < -0.35 else GRASS
    rivers = [carve_river(grid) for _ in range(RIVER_COUNT)]
    return grid, rivers


def verify_rivers():
    print("== river contiguity check (each river carved on a clean grid) ==")
    ok = True
    for i in range(8):
        random.seed(1000 + i)
        g = [[GRASS] * MAP_W for _ in range(MAP_H)]
        carve_river(g)
        arr = (np.array(g) == WATER).astype(int)
        lbl, ncomp = ndimage.label(arr, structure=[[0, 1, 0], [1, 1, 1], [0, 1, 0]])
        sizes = ndimage.sum(arr, lbl, range(1, ncomp + 1))
        biggest = int(sizes.max()) if len(sizes) else 0
        passed = biggest >= MIN_RIVER_LEN and ncomp == 1
        ok = ok and passed
        print(f"  river {i}: total_water={int(arr.sum()):4d}  components={ncomp}  "
              f"largest_4conn_run={biggest:4d}  {'PASS' if passed else 'FAIL'}")
    print("ALL RIVERS PASS" if ok else "SOME RIVERS FAILED")
    return ok


def render(grid, path, max_cells=128):
    sheet = Image.open(SHEET).convert("RGBA")

    def sprite(col, row):
        return sheet.crop((col * 32, row * 32, col * 32 + 32, row * 32 + 32))

    N = min(max_cells, MAP_W)
    # isometric extents: same math as Godot tile_size (32,16): step_x=16, step_y=8
    W = (N + N) * 16 + 32
    H = (N + N) * 8 + 64
    canvas = Image.new("RGBA", (W, H), (30, 30, 40, 255))
    ox = W // 2 - 16
    oy = 16
    for sy in range(N):          # draw back-to-front so south tiles overlap walls
        for sx in range(N):
            t = grid[sy][sx]
            pool = WATER_TILES if t == WATER else (DIRT_TILES if t == DIRT else GRASS_TILES)
            col, row = random.choice(pool)
            spr = sprite(col, row)
            px = ox + (sx - sy) * 16
            py = oy + (sx + sy) * 8
            canvas.alpha_composite(spr, (px, py))
    canvas.save(path)
    print(f"saved preview {path}  ({W}x{H}, {N}x{N} cells)")


if __name__ == "__main__":
    verify_rivers()
    random.seed(7)
    grid, rivers = generate()
    counts = {GRASS: 0, DIRT: 0, WATER: 0}
    for row in grid:
        for c in row:
            counts[c] += 1
    print("\n== full-map terrain mix (128x128) ==")
    tot = MAP_W * MAP_H
    print(f"  grass {counts[GRASS]:5d} ({counts[GRASS]/tot:.0%})  "
          f"dirt {counts[DIRT]:5d} ({counts[DIRT]/tot:.0%})  "
          f"water {counts[WATER]:5d} ({counts[WATER]/tot:.0%})")
    for i, r in enumerate(rivers):
        print(f"  river {i}: {len(r)} carved cells")
    render(grid, "/sessions/festive-kind-cori/mnt/outputs/map_preview_full.png", 128)
    render(grid, "/sessions/festive-kind-cori/mnt/outputs/map_preview_zoom.png", 48)
