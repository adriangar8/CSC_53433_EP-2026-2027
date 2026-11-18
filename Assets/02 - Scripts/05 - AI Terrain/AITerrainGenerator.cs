using UnityEngine;

// Turns a painted terrain into a realistic one with Terrain Diffusion, a diffusion model
// trained on real elevation data (github.com/xandergos/terrain-diffusion).
//
// Paint the rough layout (mountains, ridges, lowland), then press "Generate realistic terrain"
// in the Inspector, in Edit mode. The painted terrain is averaged down to a small sketch and
// stretched to real-world heights (lowland to peakHeight), the model turns it into realistic relief,
// and the result is stretched back into the height range you painted (Ctrl+Z undoes it).
// The button and the Python call are in Editor/AITerrainGeneratorEditor.cs.
[RequireComponent(typeof(Terrain))]
public class AITerrainGenerator : MonoBehaviour
{
    [Tooltip("The painted terrain is averaged down to this many cells per side before it goes to the model. " +
             "Each cell stands for 7.7 km of real land, and the result has 256 x 256 pixels per cell. " +
             "8 takes about a minute on a laptop GPU; 16 takes about four times longer.")]
    [Range(4, 16)]
    public int sketchCells = 8;

    [Tooltip("How tall your highest painted area is in the real world, in metres. Your painting is stretched so its " +
             "lowest part is lowland (100 m) and its highest part is this tall, whatever height you painted at. " +
             "The model is trained on real terrain, so this sets the style: ~500 m gives rolling hills, " +
             "~2500 m mountains, 5000 m and more high alpine ranges.")]
    [Range(300, 6000)]
    public float peakHeight = 2500;

    [Tooltip("How much random noise is mixed into your sketch before the model reads it: the model sees " +
             "cos(a) * sketch + sin(a) * noise, with a = atan(this value). Low = it follows your sketch closely, " +
             "high = it invents more of its own. In our tests: 0.01 copies the sketch (smooth, blobby shapes), " +
             "0.05 is the best balance, 0.1-0.2 drifts from the sketch, 1 and above mostly ignores it.")]
    [Range(0.01f, 1f)]
    public float noise = 0.05f;

    [Tooltip("Same sketch + same settings + same seed = same terrain. Change it to get another variation of the same sketch.")]
    [Min(0)]
    public int seed = 0;

    public const float LowlandMetres = 100f; // the lowest painted area becomes lowland at this height
    public const float CellMetres = 7680f;   // one sketch cell, in real-world metres
    public const int PixelsPerCell = 256;    // output pixels (30 m each) per sketch cell
}
