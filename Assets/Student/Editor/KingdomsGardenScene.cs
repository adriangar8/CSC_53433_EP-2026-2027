using System.IO;
using EvoSim;
using EvoSim.Neuro;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.SceneManagement;

/// <summary>
/// Builds the common-garden scene (G4) from the neural Kingdoms scene: the neural genome of every species becomes a
/// <see cref="GardenNeuralGenomeGene"/> (same settings), whose founder pool is evolved, founder and drifted networks. The
/// source run is a field of the gene: a scenario sets it per variant (path <c>red/Brain/GardenNeuralGenomeGene/sourceRun</c>),
/// or pass it here to write it into the scene. Population, floor, cap and length are the scenario's (K04).
/// </summary>
public static class KingdomsGardenScene
{
    public const string DefaultSource = "Assets/Student/Scenes/KingdomsNeural.unity";
    public const string DefaultOut = "Assets/Student/Scenes/KingdomsGarden.unity";

    [MenuItem("Tools/Kingdoms/Build Garden Scene")]
    static void BuildFromMenu() => Debug.Log("KingdomsGardenScene: " + Build());

    /// <summary>Copies <paramref name="sourceScene"/> to <paramref name="outScene"/> (overwritten) and swaps the genes.</summary>
    /// <param name="sourceRun">A run folder (relative to the project) to write into every gene, or empty to leave it to the scenario.</param>
    /// <returns>One line, or a line starting with FAILED.</returns>
    public static string Build(string sourceScene = DefaultSource, string outScene = DefaultOut, string sourceRun = "")
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
            int swapped = 0;
            foreach (var old in world.GetComponentsInChildren<NeuralGenomeGene>(true))
            {
                if (old is GardenNeuralGenomeGene) continue;
                var go = old.gameObject;
                var garden = go.AddComponent<GardenNeuralGenomeGene>();
                var from = new SerializedObject(old);
                var to = new SerializedObject(garden);
                var p = from.GetIterator();
                for (bool enter = true; p.NextVisible(enter); enter = false)
                    if (p.name != "m_Script") to.CopyFromSerializedProperty(p);
                if (sourceRun.Length > 0) to.FindProperty("sourceRun").stringValue = sourceRun;
                to.ApplyModifiedPropertiesWithoutUndo();
                Object.DestroyImmediate(old);
                swapped++;
            }
            EditorSceneManager.SaveScene(scene, outScene);
            return $"{outScene} built from {sourceScene}; {swapped} genes are garden genes";
        }
        finally
        {
            EditorSceneManager.CloseScene(scene, true);
        }
    }

    /// <summary>Command line: <c>-executeMethod KingdomsGardenScene.RunCommandLine</c>; builds, then validates the scene.</summary>
    public static void RunCommandLine()
    {
        string built = Build();
        Debug.Log("KingdomsGardenScene: " + built);
        string v = built.StartsWith("FAILED") ? "skipped" : KingdomsNeuralScene.Validate(DefaultOut);
        Debug.Log("KingdomsGardenScene validate: " + v);
        if (Application.isBatchMode) EditorApplication.Exit(built.StartsWith("FAILED") || v.StartsWith("FAILED") ? 1 : 0);
    }
}
