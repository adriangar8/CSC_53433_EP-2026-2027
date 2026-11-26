using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using EvoSim;
using EvoSim.Neuro;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.SceneManagement;

/// <summary>
/// Builds a neural copy of a Kingdoms scene: every species (red, blue) keeps its body and life settings and its diet, and gets
/// a neural brain whose weights are its genome (NeuralTemplates.Predator), no servers needed. The source scene is only copied
/// and never opened for saving. Ground, food, cover, phases and recorder stay as they are.
/// </summary>
public static class KingdomsNeuralScene
{
    public const string DefaultSource = "Assets/EvoSim/Scenes/Kingdoms.unity";
    public const string DefaultOut = "Assets/Student/Scenes/KingdomsNeural.unity";

    [MenuItem("Tools/Kingdoms/Build Neural Scene")]
    static void BuildFromMenu() => Debug.Log("KingdomsNeuralScene: " + Build());

    [MenuItem("Tools/Kingdoms/Validate Neural Scene")]
    static void ValidateFromMenu() => Debug.Log("KingdomsNeuralScene: " + Validate());

    /// <summary>Copies <paramref name="sourceScene"/> to <paramref name="outScene"/> (overwritten) and makes its species neural.</summary>
    /// <returns>One line per species, or a line starting with FAILED.</returns>
    public static string Build(string sourceScene = DefaultSource, string outScene = DefaultOut)
    {
        if (SceneManager.GetSceneByPath(sourceScene).isLoaded || SceneManager.GetSceneByPath(outScene).isLoaded)
            return "FAILED: " + sourceScene + " or " + outScene + " is open in the editor: close it first";
        Directory.CreateDirectory(Path.GetDirectoryName(outScene));
        File.Copy(sourceScene, outScene, true);
        AssetDatabase.ImportAsset(outScene, ImportAssetOptions.ForceUpdate);
        var scene = EditorSceneManager.OpenScene(outScene, OpenSceneMode.Additive);
        try
        {
            World world = null;
            foreach (var root in scene.GetRootGameObjects())
                if ((world = root.GetComponentInChildren<World>(true)) != null) break;
            if (world == null) return "FAILED: no World in " + sourceScene;

            var species = world.GetComponentsInChildren<Species>(true).ToList();
            var ids = new HashSet<string>(species.SelectMany(s => new[] { s.RequestedId, s.DisplayName }));
            var made = new List<(Species old, Species neural)>();
            foreach (var s in species)
            {
                var body = s.GetComponentInChildren<Body>(true);
                Color color = body != null ? body.Color : Color.white;
                var nn = NeuralTemplates.Predator(s, s.RequestedId + "-nn", s.DisplayName + " nn");
                Fit(nn, ids);
                var b = nn.GetComponentInChildren<Body>(true);
                if (b != null) b.Configure(b.Prefab, color, b.Size);                  // the template paints predators magenta; keep the army's colour
                made.Add((s, nn));
            }
            var lines = new List<string>();
            foreach (var (old, nn) in made)
            {
                string id = old.RequestedId, display = old.DisplayName, goName = old.gameObject.name;
                nn.transform.SetSiblingIndex(old.transform.GetSiblingIndex());
                Object.DestroyImmediate(old.gameObject);
                nn.SetNames(id, display);                                             // species ids and names stay red / blue
                nn.gameObject.name = goName;
                lines.Add($"{goName}: neural, {nn.GetComponentsInChildren<NeuralAction>(true).Length} actions");
            }
            var pairs = world.GetComponentInChildren<MatchedPairs>(true);              // the template pairs each copy with its source, which is gone
            if (pairs != null) Object.DestroyImmediate(pairs.gameObject);
            world.DefaultBrain = NeuralTemplates.BrainOf(world);
            EditorSceneManager.SaveScene(scene, outScene);
            return outScene + " built from " + sourceScene + "; " + string.Join("; ", lines);
        }
        finally
        {
            EditorSceneManager.CloseScene(scene, true);
        }
    }

    /// <summary>
    /// The template is the predator's, which sees prey, carcasses and threats but no food: a soldier also grazes. The rays and
    /// the contacts follow what the species' diet eats, so the same code fits any source scene.
    /// </summary>
    static void Fit(Species nn, HashSet<string> speciesNames)
    {
        bool graze = false, strike = false, scavenge = false;
        var diet = nn.GetComponentInChildren<Diet>(true);
        if (diet != null)
            foreach (var e in diet.Entries)
            {
                string t = (e.target ?? "").Trim();
                if (t.StartsWith("carcass:")) scavenge = true;
                else if (speciesNames.Contains(t) || speciesNames.Contains(t.Replace("-nn", ""))) strike = true;
                else graze = true;
            }
        var kinds = new List<RayHitKind>();
        if (strike) kinds.Add(RayHitKind.Prey);
        if (graze) kinds.Add(RayHitKind.Food);
        kinds.Add(RayHitKind.Kin);
        if (scavenge) kinds.Add(RayHitKind.Carcass);
        kinds.Add(RayHitKind.Cover);
        kinds.Add(RayHitKind.Obstacle);
        nn.GetComponentInChildren<RayFanSense>(true).Configure(12, 360f, kinds.ToArray());
        var contacts = (graze ? NeuralContacts.Graze : 0) | (strike ? NeuralContacts.Strike : 0) | (scavenge ? NeuralContacts.Scavenge : 0);
        foreach (var a in nn.GetComponentsInChildren<NeuralAction>(true)) a.SetContacts(contacts);
    }

    /// <summary>Initialises the world of the scene (nothing is saved) and lists its validation messages, errors first.</summary>
    public static string Validate(string scene = DefaultOut) =>
        Batch.WithScene(scene, world =>
        {
            bool ok = world.Initialize();
            var sb = new StringBuilder(ok ? "valid" : "FAILED");
            foreach (var m in world.LastReport.Messages.OrderBy(m => m.Severity != Severity.Error).ThenBy(m => m.Id))
                sb.Append($"\n  {m.Severity} {m.Id}: {m.Text}");
            return sb.ToString();
        });

    /// <summary>Command line: <c>-executeMethod KingdomsNeuralScene.RunCommandLine [-source path] [-out path]</c>; builds, then validates.</summary>
    public static void RunCommandLine()
    {
        var args = System.Environment.GetCommandLineArgs();
        string Arg(string n, string d) { for (int i = 0; i < args.Length - 1; i++) if (args[i] == n) return args[i + 1]; return d; }
        string outScene = Arg("-out", DefaultOut);
        string built = Build(Arg("-source", DefaultSource), outScene);
        Debug.Log("KingdomsNeuralScene: " + built);
        string v = built.StartsWith("FAILED") ? "skipped" : Validate(outScene);
        Debug.Log("KingdomsNeuralScene validate: " + v);
        if (Application.isBatchMode) EditorApplication.Exit(built.StartsWith("FAILED") || v.StartsWith("FAILED") ? 1 : 0);
    }
}
