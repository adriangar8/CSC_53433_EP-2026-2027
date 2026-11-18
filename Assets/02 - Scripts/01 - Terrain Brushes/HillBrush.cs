using UnityEngine;

// Raises a smooth, round hill under the cursor while the mouse is held.
// Hold Shift to dig instead.
public class HillBrush : TerrainBrush
{
    [Tooltip("Height added per second at the centre of the brush, in metres")]
    public float strength = 10;

    public override void draw(int x, int z)
    {
        float step = strength * Time.deltaTime;
        if (Input.GetKey(KeyCode.LeftShift) || Input.GetKey(KeyCode.RightShift))
            step = -step;

        for (int zi = -radius; zi <= radius; zi++)
        {
            for (int xi = -radius; xi <= radius; xi++)
            {
                // Distance from the centre, 0 at the centre and 1 on the edge of the circle
                float d = Mathf.Sqrt(xi * xi + zi * zi) / radius;
                if (d > 1)
                    continue; // outside the circle

                // Smooth falloff: 1 at the centre, 0 at the edge
                float falloff = 0.5f * (1 + Mathf.Cos(Mathf.PI * d));

                float h = terrain.get(x + xi, z + zi);
                terrain.set(x + xi, z + zi, Mathf.Max(0, h + step * falloff));
            }
        }
    }
}
