"""Bridge between Unity and Terrain Diffusion (xandergos/terrain-diffusion-30m).

Unity (AITerrainGeneratorEditor.cs) writes a job folder containing:
  job.json    {"cells": 8, "strength": 0.05, "seed": 0}
  sketch.raw  float32, cells x cells, row-major, heights in real-world metres

This script writes the sketch as a GeoTIFF, runs the model's tiff-export command,
and writes back into the same folder:
  result.raw  float32, (256 * cells) x (256 * cells), row-major, metres (30 m pixels)
  result.json {"width": ..., "height": ..., "min": ..., "max": ..., "seconds": ...}

Lines starting with "[bridge]" are shown as the status in Unity's Inspector.

Run by hand:
  python terrain_diffusion_bridge.py --job <folder> [--repo <terrain-diffusion clone>]
"""
import argparse
import json
import os
import subprocess
import sys
import time
import urllib.request
import zipfile
from pathlib import Path

import numpy as np
import rasterio
from rasterio.transform import from_origin

MODEL = "xandergos/terrain-diffusion-30m"
CELL_METRES = 7680          # one sketch cell = 256 output pixels of 30 m
PIXELS_PER_CELL = 256

# Climate rasters the pipeline needs to calibrate its random climate (downloaded once, ~50 MB)
WORLDCLIM_URL = "https://geodata.ucdavis.edu/climate/worldclim/2_1/base/wc2.1_10m_bio.zip"
WORLDCLIM_FILES = ["wc2.1_10m_bio_1.tif", "wc2.1_10m_bio_4.tif", "wc2.1_10m_bio_12.tif", "wc2.1_10m_bio_15.tif"]


def say(msg):
    print(f"[bridge] {msg}", flush=True)


def ensure_worldclim(repo: Path):
    """The model's code asks interactively for this download, which would hang under Unity."""
    data = repo / "data" / "global"
    if all((data / f).exists() for f in WORLDCLIM_FILES):
        return
    say("Downloading WorldClim climate data (first run only, ~50 MB)...")
    data.mkdir(parents=True, exist_ok=True)
    zip_path = data / "wc2.1_10m_bio.zip"
    urllib.request.urlretrieve(WORLDCLIM_URL, zip_path)
    with zipfile.ZipFile(zip_path) as z:
        z.extractall(data)
    zip_path.unlink()


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--job", required=True, type=Path, help="Folder with job.json and sketch.raw")
    p.add_argument("--repo", type=Path, default=Path(__file__).resolve().parent / "terrain-diffusion",
                   help="Clone of github.com/xandergos/terrain-diffusion")
    args = p.parse_args()
    job_dir, repo = args.job.resolve(), args.repo.resolve()
    if not (repo / "terrain_diffusion").is_dir():
        sys.exit(f"Terrain Diffusion not found in {repo}. Clone github.com/xandergos/terrain-diffusion there.")

    job = json.loads((job_dir / "job.json").read_text())
    n, strength, seed = int(job["cells"]), float(job["strength"]), max(0, int(job["seed"]))
    sketch = np.fromfile(job_dir / "sketch.raw", dtype="<f4").reshape(n, n)
    say(f"Sketch {n}x{n} cells ({n * CELL_METRES / 1000:.0f} km), heights {sketch.min():.0f}..{sketch.max():.0f} m")

    ensure_worldclim(repo)

    # 1. Sketch -> GeoTIFF, the input format of the model's tiff-export command
    cond_dir = job_dir / "cond"
    cond_dir.mkdir(exist_ok=True)
    with rasterio.open(cond_dir / "heightmap.tif", "w", driver="GTiff", height=n, width=n, count=1,
                       dtype="float32", crs="EPSG:3857",
                       transform=from_origin(0, 0, CELL_METRES, CELL_METRES)) as dst:
        dst.write(sketch.astype(np.float32), 1)

    # 2. Run the model. Strength goes in the elevation slot; the 4 climate channels keep the
    #    defaults recommended by the model's README (they are filled with random Perlin climate).
    #    The model treats seed 0 as "pick a random seed" (synthetic_map.py: `seed or random.randint(...)`),
    #    so seed 0 would give a different terrain every run. Shift by one to keep every seed reproducible.
    out_tif = job_dir / "result.tif"
    out_tif.unlink(missing_ok=True)
    say(f"Running Terrain Diffusion (strength {strength}, seed {seed})...")
    env = dict(os.environ, PYTHONIOENCODING="utf-8", PYTHONPATH=str(repo))
    t = time.perf_counter()
    subprocess.run([sys.executable, "-m", "terrain_diffusion", "tiff-export", MODEL, str(cond_dir), str(out_tif),
                    "--snr", f"{strength},0.2,1.0,0.2,1.0", "--no-compile", "--seed", str(seed + 1)],
                   cwd=repo, env=env, check=True)
    seconds = time.perf_counter() - t

    # 3. GeoTIFF -> raw float32 for Unity
    with rasterio.open(out_tif) as src:
        heights = src.read(1).astype("<f4")
    heights.tofile(job_dir / "result.raw")
    (job_dir / "result.json").write_text(json.dumps({
        "width": heights.shape[1], "height": heights.shape[0],
        "min": float(heights.min()), "max": float(heights.max()), "seconds": seconds,
    }))
    say(f"Done in {seconds:.0f} s: {heights.shape[1]}x{heights.shape[0]} px, {heights.min():.0f}..{heights.max():.0f} m")


if __name__ == "__main__":
    main()
