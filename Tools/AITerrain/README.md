# AI terrain: Terrain Diffusion in Unity

Paint the rough layout of a terrain with the brushes, press one button, and a diffusion model
trained on real elevation data turns it into realistic relief.

- Model: [Terrain Diffusion](https://github.com/xandergos/terrain-diffusion) (`xandergos/terrain-diffusion-30m`, MIT licence)
- Unity side: `Assets/02 - Scripts/05 - AI Terrain/AITerrainGenerator.cs` and `Assets/02 - Scripts/Editor/AITerrainGeneratorEditor.cs`
- Python side: `terrain_diffusion_bridge.py` (this folder)

## Setup (once per computer)

You need an NVIDIA GPU with at least 4 GB of memory. A CPU works, but it is much slower.

1. Clone the model code into this folder. It is ignored by git.
   ```
   cd Tools/AITerrain
   git clone --depth 1 https://github.com/xandergos/terrain-diffusion
   ```
2. In a Python 3.11 environment, install PyTorch with CUDA and then the model's requirements:
   ```
   pip install torch torchvision --index-url https://download.pytorch.org/whl/cu128
   pip install -r terrain-diffusion/requirements.txt
   ```
   The first run also downloads the model (about 1.1 GB, cached by Hugging Face) and
   WorldClim climate data (about 50 MB, into `terrain-diffusion/data/global`).

## Use

1. Select the **Terrain** and add the **AI Terrain Generator** component.
2. Under **This computer**, set **Python** to the `python.exe` of the environment from step 2,
   for example `C:\Users\<you>\miniconda3\envs\<env>\python.exe`. This is saved per computer, not in the scene.
3. Paint the layout: high areas become mountains and low areas lowland. The model only reads the
   average height of each sketch cell, so paint broad shapes, not details. The **What the AI sees**
   grid in the Inspector shows exactly what the model will get (seen from above, back at the top) and
   updates as you paint. The highest cell always becomes the peak, so flatten leftovers you don't want.
4. In **Edit mode**, press **Generate realistic terrain**. With 8 sketch cells it takes about a minute
   on a laptop GPU, and the editor stays usable meanwhile. **Ctrl+Z** undoes it.
5. Change **Seed** to get another variation of the same sketch. The same sketch and seed always
   give the same terrain.

| Setting | Meaning |
|---|---|
| Sketch Cells | The terrain is averaged to this many cells per side. Each cell is 7.7 km of real land and becomes 256 x 256 pixels of 30 m. |
| Peak Height | How tall your highest painted area is in the real world. Your painting is stretched so its lowest part is lowland (100 m) and its highest part is this tall, so you can paint at any height. It also sets the style: about 500 m gives rolling hills, about 2500 m mountains. The result is stretched back into the height range you painted. |
| Noise | How much random noise is mixed into the sketch before the model reads it (`cos(a) * sketch + sin(a) * noise`, with `a = atan(Noise)`). The model is told how noisy its input is, so low values make it follow the sketch and high values make it invent more. In our tests: 0.01 copies the sketch with smooth, blobby shapes; **0.05 (default)** is the best balance; 0.1-0.2 drifts from the sketch; 1 and above mostly ignores it. |
| Seed | Which variation. |

## How it works

1. Unity averages the heightmap to `Sketch Cells` x `Sketch Cells` cells, stretches them to 100 m .. `Peak Height`, and writes them to `Temp/AITerrain/`.
2. `terrain_diffusion_bridge.py` writes them as a GeoTIFF and runs the model's `tiff-export`. The model has three stages:
   - a coarse model reads the sketch;
   - a latent model makes the large valleys and ridges at 240 m per pixel;
   - a decoder adds 30 m detail.
3. Unity resamples the result to the terrain's heightmap resolution and applies it, with Undo.

The bridge passes `seed + 1` to the model, because the model treats seed 0 as "random"
(`synthetic_map.py`: `seed or random.randint(...)`).

If something fails, the Inspector shows the last lines of Python's output and the full log is in `Temp/AITerrain/log.txt`.

## Physics baseline: stream power erosion

`Assets/02 - Scripts/05 - AI Terrain/StreamPowerErosion.cs` carves the terrain with the stream power law,
`E = K * A^m * S` (erosion grows with drainage area A and slope S), without any AI and without Python.
Add **Stream Power Erosion** to the Terrain and press **Erode** in Edit mode (Ctrl+Z undoes it).
Two more processes run in the same loop:
- **hillslope diffusion** (`dh/dt = D * laplacian(h)`, soil creep) rounds ridges and hilltops;
- **thermal erosion** turns slopes steeper than the talus angle into scree.

Set Erodibility or Diffusion to 0, or Talus Angle to 90, to switch a process off and compare them one at a time.
The defaults (50 iterations, K = 0.02, m = 0.5, roughness 0.002, D = 0.05, talus 45°) cut gullies into painted slopes
and keep the painted shapes. With K above about 0.05 the shapes erode away, and with D above about 0.1 the gullies disappear.
Smoothing also shows an artefact of the 8-direction flow routing: round hills become slightly octagonal. Compare it with the AI generator:
physics gives you control over the process, while the AI reproduces what real terrain looks like.
