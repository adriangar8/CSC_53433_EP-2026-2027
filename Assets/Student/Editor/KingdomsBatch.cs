using System;
using System.Linq;
using System.Text;
using EvoSim;
using UnityEditor;
using UnityEngine;

/// <summary>
/// Runs scenario assets from Assets/Student/Scenarios (EvoSim.Batch.FindScenario only searches Assets/EvoSim/Scenarios).
/// From the open editor: <c>KingdomsBatch.RunNamed("K01_KingdomsDemography", "base", 1)</c> (the scene must not be open).
/// From the command line: <c>-batchmode -executeMethod KingdomsBatch.RunCommandLine -asset K01_KingdomsDemography
/// [-variant v] [-seed n] [-ticks n]</c>; exit code 0, 1 if a run FAILED, 2 on an exception.
/// </summary>
public static class KingdomsBatch
{
    /// <summary>Runs every variant (or the one named) and every seed (or the one given) of the asset; one summary line per run.</summary>
    public static string RunNamed(string asset, string variant = "", int seed = -1, int ticks = -1)
    {
        var scenario = AssetDatabase.LoadAssetAtPath<ScenarioAsset>($"Assets/Student/Scenarios/{asset}.asset");
        if (scenario == null) return "FAILED: no scenario asset " + asset;
        if (variant != "" && !scenario.variants.Any(v => v.name == variant)) return "FAILED: no variant " + variant;
        var sb = new StringBuilder();
        foreach (var v in scenario.variants.Where(v => variant == "" || v.name == variant))
            foreach (var s in seed >= 0 ? new[] { seed } : scenario.seeds.ToArray())
                sb.AppendLine(Batch.Run(scenario, v.name, s, ticks >= 0 ? ticks : (int?)null, null, WaitMode.Freeze));
        return sb.ToString().TrimEnd();
    }

    /// <summary>Command-line entry point; see the class summary.</summary>
    public static void RunCommandLine()
    {
        int code = 0;
        try
        {
            string asset = Arg("-asset") ?? throw new ArgumentException("-asset is required");
            string seed = Arg("-seed"), ticks = Arg("-ticks");
            foreach (var line in RunNamed(asset, Arg("-variant") ?? "", seed != null ? int.Parse(seed) : -1, ticks != null ? int.Parse(ticks) : -1).Split('\n'))
            {
                Debug.Log("EvoSim scenario: " + line);
                if (line.StartsWith("FAILED")) code = 1;
            }
        }
        catch (Exception e)
        {
            Debug.LogException(e);
            code = 2;
        }
        if (Application.isBatchMode) EditorApplication.Exit(code);
    }

    static string Arg(string name)
    {
        var args = Environment.GetCommandLineArgs();
        for (int i = 0; i < args.Length - 1; i++) if (args[i] == name) return args[i + 1];
        return null;
    }
}
