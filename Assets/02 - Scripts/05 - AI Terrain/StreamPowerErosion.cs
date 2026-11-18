using UnityEngine;

// Stream power law erosion: a physics model of rivers cutting into terrain, to compare with the AI.
//
//   erosion rate E = K * A^m * S
//
// A is the drainage area (how much land drains through a point), S the slope, K how easily the
// ground erodes. Points where a lot of water flows down a steep slope erode fastest, which carves
// gullies and valleys.
//
// Each iteration:
//   1. Flow routing: every point drains to its steepest lower neighbour (8 neighbours).
//   2. Drainage area: going from the highest point down, each point passes its area on downstream.
//   3. Erosion: going from the lowest point up, each point is lowered towards its downstream
//      neighbour. This is the implicit scheme of Braun & Willett (2013): stable for any K.
//   4. Hillslope diffusion (soil creep): dh/dt = D * laplacian(h). Rounds hilltops and ridges.
//   5. Thermal erosion: where a slope is steeper than the talus angle, material slides down to the
//      steepest lower neighbour. Turns cliffs into scree slopes.
// The edges of the terrain are outlets and do not erode. Press "Erode" in the Inspector (Edit mode).
// Set erodibility, diffusion to 0 or talus angle to 90 to switch a process off and compare.
[RequireComponent(typeof(Terrain))]
public class StreamPowerErosion : MonoBehaviour
{
    [Tooltip("Number of erosion steps per click. More = deeper valleys.")]
    [Range(1, 200)]
    public int iterations = 50;

    [Tooltip("K: how easily the ground erodes. Higher = faster erosion; above ~0.05 your painted shapes disappear.")]
    [Range(0f, 0.1f)]
    public float erodibility = 0.02f;

    [Tooltip("m: how much the drainage area matters. Higher = big rivers dominate. 0.5 is the usual value.")]
    [Range(0.2f, 0.8f)]
    public float areaExponent = 0.5f;

    [Tooltip("Tiny random bumps (in terrain height, 0..1) added before eroding, so water can pick different paths " +
             "on perfectly smooth painted slopes. Without them, gullies come out as straight lines.")]
    [Range(0f, 0.01f)]
    public float roughness = 0.002f;

    [Header("Hillslope diffusion")]
    [Tooltip("D: soil creep, smooths the terrain a little every step. 0 = off. Above ~0.1 it wipes out the gullies; " +
             "above 0.25 the method becomes unstable.")]
    [Range(0f, 0.25f)]
    public float diffusion = 0.05f;

    [Header("Thermal erosion")]
    [Tooltip("Slopes steeper than this angle (in degrees) collapse into scree. 90 = off. Real rock and soil: 30-45.")]
    [Range(10f, 90f)]
    public float talusAngle = 45f;

    // The 8 neighbours
    static readonly int[] DX = { -1, 0, 1, -1, 1, -1, 0, 1 };
    static readonly int[] DZ = { -1, -1, -1, 0, 0, 1, 1, 1 };

    public void Erode()
    {
        TerrainData data = GetComponent<Terrain>().terrainData;
        int res = data.heightmapResolution;
        int n = res * res;
        float[,] grid = data.GetHeights(0, 0, res, res);   // [z, x], 0..1

        // Flatten to a 1D array (index = z * res + x) and add the roughness
        var h = new float[n];
        var random = new System.Random(0);
        for (int z = 0; z < res; z++)
            for (int x = 0; x < res; x++)
                h[z * res + x] = grid[z, x] + (float)random.NextDouble() * roughness;

        var receiver = new int[n];   // where each point drains to (itself if it has no lower neighbour)
        var distance = new float[n]; // distance to the receiver, in grid cells (1 or 1.41)
        var area = new float[n];     // drainage area, in grid cells
        var order = new int[n];      // points sorted from lowest to highest
        var sortKeys = new float[n];
        var change = new float[n];   // height changes of steps 4 and 5, applied all at once

        // Talus angle -> largest allowed height difference between neighbours, in terrain height units (0..1)
        float cellSize = data.size.x / (res - 1);
        float maxDrop = talusAngle >= 90 ? float.MaxValue : Mathf.Tan(talusAngle * Mathf.Deg2Rad) * cellSize / data.size.y;

        for (int it = 0; it < iterations; it++)
        {
            // 1. Flow routing: steepest lower neighbour
            for (int z = 0; z < res; z++)
            {
                for (int x = 0; x < res; x++)
                {
                    int i = z * res + x;
                    receiver[i] = i;
                    distance[i] = 1;
                    if (x == 0 || z == 0 || x == res - 1 || z == res - 1)
                        continue;   // edges are outlets
                    float steepest = 0;
                    for (int k = 0; k < 8; k++)
                    {
                        int j = (z + DZ[k]) * res + (x + DX[k]);
                        float d = (DX[k] != 0 && DZ[k] != 0) ? 1.41421f : 1f;
                        float slope = (h[i] - h[j]) / d;
                        if (slope > steepest)
                        {
                            steepest = slope;
                            receiver[i] = j;
                            distance[i] = d;
                        }
                    }
                }
            }

            // Sort points from lowest to highest
            for (int i = 0; i < n; i++)
            {
                order[i] = i;
                sortKeys[i] = h[i];
            }
            System.Array.Sort(sortKeys, order);

            // 2. Drainage area: from the highest point down, pass the area to the receiver
            for (int i = 0; i < n; i++)
                area[i] = 1;
            for (int k = n - 1; k >= 0; k--)
            {
                int i = order[k];
                if (receiver[i] != i)
                    area[receiver[i]] += area[i];
            }

            // 3. Erosion, from the lowest point up, so each receiver is already updated:
            //    h_new = (h + F * h_receiver_new) / (1 + F),  with F = K * A^m / distance
            for (int k = 0; k < n; k++)
            {
                int i = order[k];
                int r = receiver[i];
                if (r == i)
                    continue;
                float f = erodibility * Mathf.Pow(area[i], areaExponent) / distance[i];
                h[i] = (h[i] + f * h[r]) / (1 + f);
            }

            // 4. Hillslope diffusion: h += D * (sum of the 4 neighbours - 4 h)
            if (diffusion > 0)
            {
                for (int z = 1; z < res - 1; z++)
                {
                    for (int x = 1; x < res - 1; x++)
                    {
                        int i = z * res + x;
                        change[i] = diffusion * (h[i - 1] + h[i + 1] + h[i - res] + h[i + res] - 4 * h[i]);
                    }
                }
                Apply(h, change);
            }

            // 5. Thermal erosion: move part of the height above the talus slope to the steepest lower neighbour
            if (talusAngle < 90)
            {
                for (int z = 1; z < res - 1; z++)
                {
                    for (int x = 1; x < res - 1; x++)
                    {
                        int i = z * res + x;
                        int target = i;
                        float largestExcess = 0;
                        for (int k = 0; k < 8; k++)
                        {
                            int j = (z + DZ[k]) * res + (x + DX[k]);
                            float d = (DX[k] != 0 && DZ[k] != 0) ? 1.41421f : 1f;
                            float excess = h[i] - h[j] - maxDrop * d;
                            if (excess > largestExcess)
                            {
                                largestExcess = excess;
                                target = j;
                            }
                        }
                        // Moving half the excess would exactly level the slope; move a quarter so it settles smoothly
                        float moved = largestExcess / 4;
                        change[i] -= moved;
                        change[target] += moved;
                    }
                }
                Apply(h, change);
            }
        }

        for (int z = 0; z < res; z++)
            for (int x = 0; x < res; x++)
                grid[z, x] = Mathf.Clamp01(h[z * res + x]);
        data.SetHeights(0, 0, grid);
    }

    // Add the changes to the heights and reset them to zero
    static void Apply(float[] h, float[] change)
    {
        for (int i = 0; i < h.Length; i++)
        {
            h[i] += change[i];
            change[i] = 0;
        }
    }
}
