using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading.Tasks;
using UnityEditor;
using UnityEngine;
using Debug = UnityEngine.Debug;

// Inspector for AITerrainGenerator: the "Generate realistic terrain" button.
//
// Round trip:
//   1. Average the terrain's heightmap down to sketchCells x sketchCells heights in metres
//      and write it to <project>/Temp/AITerrain/sketch.raw (+ job.json).
//   2. Run Tools/AITerrain/terrain_diffusion_bridge.py in the background; it runs the model
//      and writes result.raw (256 x 256 pixels of 30 m per sketch cell).
//   3. Resample the result to the terrain's heightmap resolution and apply it, with Undo.
[CustomEditor(typeof(AITerrainGenerator))]
public class AITerrainGeneratorEditor : Editor
{
    // Per-computer settings live in EditorPrefs, not in the scene, so each student sets their own.
    const string PythonPref = "AITerrain.Python";
    const string RepoPref = "AITerrain.Repo";

    static bool running;
    static string status = "";
    static DateTime started;

    static string ProjectRoot => Path.GetDirectoryName(Application.dataPath);
    static string BridgeScript => Path.Combine(ProjectRoot, "Tools", "AITerrain", "terrain_diffusion_bridge.py");
    static string DefaultRepo => Path.Combine(ProjectRoot, "Tools", "AITerrain", "terrain-diffusion");
    static string JobDir => Path.Combine(ProjectRoot, "Temp", "AITerrain");

    [Serializable] class Job { public int cells; public float strength; public int seed; }
#pragma warning disable 0649   // filled by JsonUtility
    [Serializable] class Result { public int width; public int height; public float min; public float max; public float seconds; }
#pragma warning restore 0649

    public override void OnInspectorGUI()
    {
        DrawDefaultInspector();
        var gen = (AITerrainGenerator)target;

        int n = gen.sketchCells;
        float km = n * AITerrainGenerator.CellMetres / 1000f;
        int px = n * AITerrainGenerator.PixelsPerCell;
        EditorGUILayout.HelpBox($"The terrain stands for {km:0} x {km:0} km of real land. " +
                                $"The model generates {px} x {px} pixels of 30 m.", MessageType.Info);

        DrawSketchPreview(gen);

        EditorGUILayout.Space();
        EditorGUILayout.LabelField("This computer", EditorStyles.boldLabel);
        using (new EditorGUILayout.HorizontalScope())
        {
            EditorPrefs.SetString(PythonPref, EditorGUILayout.TextField(
                new GUIContent("Python", "python.exe of the environment with PyTorch and Terrain Diffusion's requirements"),
                EditorPrefs.GetString(PythonPref, "python")));
            if (GUILayout.Button("Browse...", GUILayout.Width(70)))
            {
                string picked = EditorUtility.OpenFilePanel("Choose python.exe", "", "exe");
                if (!string.IsNullOrEmpty(picked))
                {
                    EditorPrefs.SetString(PythonPref, picked);
                    GUI.FocusControl(null);   // so the text field shows the new value
                }
            }
        }
        EditorPrefs.SetString(RepoPref, EditorGUILayout.TextField(
            new GUIContent("Terrain Diffusion folder", "Clone of github.com/xandergos/terrain-diffusion"),
            EditorPrefs.GetString(RepoPref, DefaultRepo)));

        EditorGUILayout.Space();
        if (Application.isPlaying)
        {
            EditorGUILayout.HelpBox("Exit Play mode to generate.", MessageType.None);
            return;
        }

        using (new EditorGUI.DisabledScope(running))
        {
            if (GUILayout.Button(running ? "Generating..." : "Generate realistic terrain", GUILayout.Height(30)))
                Generate(gen, EditorPrefs.GetString(PythonPref, "python"), EditorPrefs.GetString(RepoPref, DefaultRepo));
        }

        if (running)
        {
            EditorGUILayout.HelpBox($"{status}\n{(DateTime.Now - started).TotalSeconds:0} s", MessageType.None);
            Repaint();
        }
        else if (status != "")
        {
            EditorGUILayout.HelpBox(status, MessageType.None);
        }
    }

    static async void Generate(AITerrainGenerator gen, string python, string repo)
    {
        TerrainData data = gen.GetComponent<Terrain>().terrainData;
        int n = gen.sketchCells;
        float lowland = AITerrainGenerator.LowlandMetres;
        float peak = Mathf.Max(gen.peakHeight, lowland + 100);   // same as the preview
        running = true;
        started = DateTime.Now;
        status = "Exporting the sketch...";
        try
        {
            Directory.CreateDirectory(JobDir);
            string resultRaw = Path.Combine(JobDir, "result.raw");
            string resultJson = Path.Combine(JobDir, "result.json");
            string logPath = Path.Combine(JobDir, "log.txt");
            File.Delete(resultRaw);
            File.Delete(resultJson);

            // 1. Painted terrain -> sketch in real-world metres (the same numbers the preview shows)
            int res = data.heightmapResolution;
            float[,] h = data.GetHeights(0, 0, res, res);   // [z, x], 0..1
            Sketch s = MakeSketch(h, res, n, peak);
            if (s.flat)
                throw new Exception("The terrain is flat at this scale. Paint some broad high and low areas first " +
                                    $"(each sketch cell is 1/{n} of the terrain's width).");
            WriteFloats(Path.Combine(JobDir, "sketch.raw"), s.metres);
            float paintedLow = s.paintedLow, paintedHigh = s.paintedHigh;   // the result is fitted into this (step 3)
            File.WriteAllText(Path.Combine(JobDir, "job.json"), JsonUtility.ToJson(
                new Job { cells = n, strength = gen.noise, seed = gen.seed }));

            // 2. Run the model through the Python bridge, without blocking the editor
            status = "Starting Python...";
            var log = new StringBuilder();
            var psi = new ProcessStartInfo(python, $"\"{BridgeScript}\" --job \"{JobDir}\" --repo \"{repo}\"")
            {
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true,
                WorkingDirectory = ProjectRoot,
            };
            psi.EnvironmentVariables["PYTHONIOENCODING"] = "utf-8";
            psi.EnvironmentVariables["PYTHONUNBUFFERED"] = "1";

            int exitCode;
            using (var proc = new Process { StartInfo = psi })
            {
                DataReceivedEventHandler onLine = (s, e) =>
                {
                    if (e.Data == null) return;
                    lock (log) log.AppendLine(e.Data);
                    if (e.Data.StartsWith("[bridge] ")) status = e.Data.Substring(9);
                };
                proc.OutputDataReceived += onLine;
                proc.ErrorDataReceived += onLine;
                try
                {
                    proc.Start();
                }
                catch (Win32Exception)
                {
                    throw new Exception($"Could not start Python \"{python}\". Set the Python field to the python.exe " +
                                        "of the environment where Terrain Diffusion is installed.");
                }
                proc.BeginOutputReadLine();
                proc.BeginErrorReadLine();
                await Task.Run(() => proc.WaitForExit());
                exitCode = proc.ExitCode;
            }
            string logText;
            lock (log) logText = log.ToString();
            File.WriteAllText(logPath, logText);
            if (exitCode != 0 || !File.Exists(resultRaw))
            {
                string hint = logText.Contains("ModuleNotFoundError")
                    ? $"\nThe Python \"{python}\" is missing packages. Set the Python field to the python.exe of the " +
                      "environment where you installed Terrain Diffusion's requirements (see Tools/AITerrain/README.md)."
                    : "";
                throw new Exception($"Python failed (exit code {exitCode}):\n{Tail(logText, 12)}{hint}\nFull log: {logPath}");
            }

            // 3. Result -> terrain
            if (data == null) throw new Exception("The terrain was deleted while generating.");
            var result = JsonUtility.FromJson<Result>(File.ReadAllText(resultJson));
            float[] metres = ReadFloats(resultRaw, result.width * result.height);
            // Fit the result's real height range exactly into the painted range:
            // its lowest point lands on your lowest point, its highest on your highest.
            var toUnity = new HeightMapping
            {
                metres0 = result.min, unity0 = paintedLow,
                unityPerMetre = (paintedHigh - paintedLow) / Mathf.Max(1f, result.max - result.min),
            };
            float[,] heights = Resample(metres, result.height, result.width, res, toUnity);

            Undo.RegisterCompleteObjectUndo(data, "Generate realistic terrain");
            data.SetHeights(0, 0, heights);
            EditorUtility.SetDirty(data);

            status = $"Done in {(DateTime.Now - started).TotalSeconds:0} s. Real heights {result.min:0} to {result.max:0} m. " +
                     "Ctrl+Z to undo.";
            // How much steeper the Unity terrain is than the real landscape it stands for
            float unityMetresPerRealMetre = toUnity.unityPerMetre * data.size.y;
            float horizontal = data.size.x / (n * AITerrainGenerator.CellMetres);
            Debug.Log($"AI terrain: {status}\nYour sketch was read as {lowland:0}..{peak:0} m over " +
                      $"{n * AITerrainGenerator.CellMetres / 1000:0} km. The result ({result.min:0}..{result.max:0} m) was fitted " +
                      $"into your painted range {paintedLow * data.size.y:0.#}..{paintedHigh * data.size.y:0.#} (Unity units). " +
                      $"Relief is exaggerated {unityMetresPerRealMetre / horizontal:0.#}x compared with the real world.");
        }
        catch (Exception e)
        {
            status = "Failed: " + e.Message;
            Debug.LogError("AI terrain: " + e.Message);
        }
        finally
        {
            running = false;
        }
    }

    // ------------------------------------------------------------------ sketch

    // What the model sees: the painted heightmap averaged over n x n cells, then stretched so the
    // lowest cell is lowland and the highest cell is the peak height. Whatever height range you
    // painted in, the model always gets a realistic one.
    struct Sketch
    {
        public float[] metres;                 // n x n, row-major, row 0 = front (z = 0)
        public float cellLow, cellHigh;        // lowest / highest cell average (Unity 0..1)
        public float paintedLow, paintedHigh;  // lowest / highest painted point (Unity 0..1)
        public bool flat;
    }

    static Sketch MakeSketch(float[,] h, int res, int n, float peak)
    {
        float lowland = AITerrainGenerator.LowlandMetres;
        var s = new Sketch { metres = new float[n * n], paintedLow = float.MaxValue, paintedHigh = float.MinValue };
        foreach (float v in h) { s.paintedLow = Mathf.Min(s.paintedLow, v); s.paintedHigh = Mathf.Max(s.paintedHigh, v); }
        for (int ci = 0; ci < n; ci++)
        {
            for (int cj = 0; cj < n; cj++)
            {
                int z0 = ci * res / n, z1 = (ci + 1) * res / n;
                int x0 = cj * res / n, x1 = (cj + 1) * res / n;
                double sum = 0;
                for (int z = z0; z < z1; z++)
                    for (int x = x0; x < x1; x++)
                        sum += h[z, x];
                s.metres[ci * n + cj] = (float)(sum / ((z1 - z0) * (x1 - x0)));
            }
        }
        s.cellLow = Mathf.Min(s.metres);
        s.cellHigh = Mathf.Max(s.metres);
        s.flat = s.cellHigh - s.cellLow < 1e-4f;
        for (int i = 0; i < s.metres.Length; i++)
            s.metres[i] = s.flat ? lowland : lowland + (s.metres[i] - s.cellLow) / (s.cellHigh - s.cellLow) * (peak - lowland);
        return s;
    }

    // ------------------------------------------------------------------ preview

    Sketch preview;
    bool previewDirty = true;
    int previewN;
    float previewPeak;

    void OnEnable()
    {
        TerrainCallbacks.heightmapChanged += OnHeightmapChanged;
        Undo.undoRedoPerformed += OnUndoRedo;
    }

    void OnDisable()
    {
        TerrainCallbacks.heightmapChanged -= OnHeightmapChanged;
        Undo.undoRedoPerformed -= OnUndoRedo;
    }

    void OnUndoRedo()
    {
        previewDirty = true;
        Repaint();
    }

    void OnHeightmapChanged(Terrain terrain, RectInt region, bool synched)
    {
        if (target != null && terrain == ((AITerrainGenerator)target).GetComponent<Terrain>())
        {
            previewDirty = true;
            Repaint();
        }
    }

    void DrawSketchPreview(AITerrainGenerator gen)
    {
        TerrainData data = gen.GetComponent<Terrain>().terrainData;
        if (data == null) return;
        int n = gen.sketchCells;
        float peak = Mathf.Max(gen.peakHeight, AITerrainGenerator.LowlandMetres + 100);
        if (previewDirty || previewN != n || previewPeak != peak || preview.metres == null)
        {
            int res = data.heightmapResolution;
            preview = MakeSketch(data.GetHeights(0, 0, res, res), res, n, peak);
            previewDirty = false;
            previewN = n;
            previewPeak = peak;
        }

        EditorGUILayout.Space();
        EditorGUILayout.LabelField(new GUIContent("What the AI sees",
            "Each cell is the average height of 1/" + n + " of the terrain's width, stretched so the lowest cell is " +
            AITerrainGenerator.LowlandMetres + " m and the highest is the peak height. Seen from above."), EditorStyles.boldLabel);
        if (preview.flat)
        {
            EditorGUILayout.HelpBox("Flat at this scale: paint some broad high and low areas.", MessageType.Warning);
            return;
        }

        var centred = new GUIStyle(EditorStyles.centeredGreyMiniLabel) { alignment = TextAnchor.MiddleCenter };
        GUILayout.Label("Back (+Z)", centred);
        float size = Mathf.Min(EditorGUIUtility.currentViewWidth - 40, 320);
        Rect area = GUILayoutUtility.GetRect(size, size, GUILayout.ExpandWidth(false));
        area.x = (EditorGUIUtility.currentViewWidth - size) / 2;
        float cell = size / n;
        var label = new GUIStyle(EditorStyles.miniLabel) { alignment = TextAnchor.MiddleCenter, fontSize = n > 10 ? 7 : 9 };
        for (int ci = 0; ci < n; ci++)
        {
            for (int cj = 0; cj < n; cj++)
            {
                float m = preview.metres[ci * n + cj];
                float t = (m - AITerrainGenerator.LowlandMetres) / (peak - AITerrainGenerator.LowlandMetres);
                // row 0 is the front of the terrain, so it is drawn at the bottom
                var r = new Rect(area.x + cj * cell, area.yMax - (ci + 1) * cell, cell - 1, cell - 1);
                Color c = HeightColour(t);
                EditorGUI.DrawRect(r, c);
                label.normal.textColor = c.grayscale > 0.55f ? Color.black : Color.white;
                GUI.Label(r, m.ToString("0"), label);
            }
        }
        GUILayout.Label("Front", centred);

        // Thin strokes vanish in the averages: warn when the cells span much less than the painted range
        float cellRange = preview.cellHigh - preview.cellLow, paintedRange = preview.paintedHigh - preview.paintedLow;
        if (cellRange < 0.35f * paintedRange)
            EditorGUILayout.HelpBox($"Your tallest strokes average out to only {100 * cellRange / paintedRange:0}% of their height " +
                                    $"in these cells: they are too thin to survive. Paint broader shapes, at least 1/{n} of " +
                                    "the terrain wide, and flatten leftovers you do not want: the highest cell always " +
                                    "becomes the peak.", MessageType.Warning);
    }

    // Low = green, middle = tan, high = white, like a relief map
    static Color HeightColour(float t)
    {
        t = Mathf.Clamp01(t);
        var low = new Color(0.25f, 0.5f, 0.3f);
        var mid = new Color(0.75f, 0.65f, 0.45f);
        var high = new Color(0.97f, 0.97f, 0.97f);
        return t < 0.5f ? Color.Lerp(low, mid, t * 2) : Color.Lerp(mid, high, t * 2 - 1);
    }

    // ------------------------------------------------------------------ helpers

    // Real-world metres -> Unity height (0..1): unity0 + (metres - metres0) * unityPerMetre
    struct HeightMapping { public float metres0, unity0, unityPerMetre; }

    // Model output (metres, sh x sw) -> Unity heights (0..1, res x res).
    // Box-average when shrinking (keeps ridges from aliasing), bilinear when enlarging.
    static float[,] Resample(float[] src, int sh, int sw, int res, HeightMapping map)
    {
        var dst = new float[res, res];
        float sy = (float)sh / res, sx = (float)sw / res;   // source pixels per target pixel
        bool shrink = sy >= 1 && sx >= 1;
        for (int i = 0; i < res; i++)
        {
            for (int j = 0; j < res; j++)
            {
                float m;
                if (shrink)
                {
                    int y0 = (int)(i * sy), y1 = Math.Min(sh, Math.Max(y0 + 1, (int)((i + 1) * sy)));
                    int x0 = (int)(j * sx), x1 = Math.Min(sw, Math.Max(x0 + 1, (int)((j + 1) * sx)));
                    double sum = 0;
                    for (int y = y0; y < y1; y++)
                        for (int x = x0; x < x1; x++)
                            sum += src[y * sw + x];
                    m = (float)(sum / ((y1 - y0) * (x1 - x0)));
                }
                else
                {
                    float u = i * (sh - 1f) / (res - 1), v = j * (sw - 1f) / (res - 1);
                    int y = Math.Min((int)u, sh - 2), x = Math.Min((int)v, sw - 2);
                    float fy = u - y, fx = v - x;
                    m = Mathf.Lerp(Mathf.Lerp(src[y * sw + x], src[y * sw + x + 1], fx),
                                   Mathf.Lerp(src[(y + 1) * sw + x], src[(y + 1) * sw + x + 1], fx), fy);
                }
                dst[i, j] = Mathf.Clamp01(map.unity0 + (m - map.metres0) * map.unityPerMetre);
            }
        }
        return dst;
    }

    static void WriteFloats(string path, float[] values)
    {
        var bytes = new byte[values.Length * 4];
        Buffer.BlockCopy(values, 0, bytes, 0, bytes.Length);
        File.WriteAllBytes(path, bytes);
    }

    static float[] ReadFloats(string path, int count)
    {
        byte[] bytes = File.ReadAllBytes(path);
        if (bytes.Length != count * 4)
            throw new Exception($"{path} has {bytes.Length} bytes, expected {count * 4}.");
        var values = new float[count];
        Buffer.BlockCopy(bytes, 0, values, 0, bytes.Length);
        return values;
    }

    static string Tail(string text, int lines)
    {
        string[] all = text.Replace("\r", "\n").Split(new[] { '\n' }, StringSplitOptions.RemoveEmptyEntries);
        return string.Join("\n", all, Math.Max(0, all.Length - lines), Math.Min(lines, all.Length));
    }
}
