using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using EvoSim;
using EvoSim.Neuro;
using UnityEngine;

/// <summary>
/// A neural genome whose founder pool is a common garden (G4): three equal groups of networks released together, each
/// tagged with its own origin label, so a run can compare their survival and offspring.
/// </summary>
/// <remarks>
/// <para><b>Groups.</b> <c>evolved</c>: the living soldiers of a source run that are not founders or immigrants (generation
/// at least 1), for one army (the one with the higher mean generation, or <see cref="sourceSpecies"/>). <c>founder</c>:
/// networks of the standard founder pool. <c>drifted</c>: other networks of the standard pool, each with k mutations of the
/// species' own <see cref="NeuralMutation"/>, where k is the mean number of mutation events carried by the evolved genomes
/// (<see cref="mutationsOverride"/> ≥ 0 sets it). Every group has as many networks as there are evolved ones.</para>
/// <para><b>Origin tag.</b> The existing <see cref="FounderAllele.Origin"/>, so <c>alleles.jsonl</c> shows <c>evolved</c>,
/// <c>founder</c> or <c>drifted</c> for every founder allele and an animal's origin is the origin of its founder allele.</para>
/// <para><b>k.</b> From the source run's <c>alleles.jsonl</c>: a mutation allele (operator <c>nn-*</c>) carries its parent's
/// load plus 1, a recombinant of two parents the mean of theirs (each neuron comes from one parent), a founder 0.</para>
/// <para><b>Randomness.</b> Only the world's <c>garden</c> stream of the species (so the pool follows the run seed), and no
/// <c>UnityEngine.Random</c>. With the source run empty the gene is the plain neural gene.</para>
/// <para>The founders of a run are drawn at random from the pool, so the three cohorts are equal in expectation, not exactly.</para>
/// </remarks>
public class GardenNeuralGenomeGene : NeuralGenomeGene
{
    [SerializeField, Tooltip("The source run's folder (final_population.json, vectors.jsonl, alleles.jsonl), relative to the project root.")]
    string sourceRun = "";
    [SerializeField, Tooltip("The source army's species id; empty: the one with the higher mean generation.")]
    string sourceSpecies = "";
    [SerializeField, Tooltip("Mutations applied to each drifted network; negative: the evolved genomes' mean load.")]
    float mutationsOverride = -1f;

    List<FounderAllele> garden;

    /// <summary>What the last build did: group size, source army, k.</summary>
    public string Summary { get; private set; } = "";

    /// <inheritdoc/>
    public override void Initialize()
    {
        base.Initialize();
        garden = null;
    }

    /// <inheritdoc/>
    public override IReadOnlyList<FounderAllele> FounderPool => string.IsNullOrEmpty(sourceRun) ? base.FounderPool : garden ??= Build();

    [Serializable] class Soldier { public int gen; public string[] genome; public string species; }
    [Serializable] class Soldiers { public Soldier[] items; }
    [Serializable] class Vector { public string id; public float[] values; }
    [Serializable] class AlleleRow { public string id; public string @operator; public string parent_id; public string parent2_id; }

    List<FounderAllele> Build()
    {
        string folder = Path.GetFullPath(Path.Combine(Application.dataPath, "..", sourceRun));
        var all = JsonUtility.FromJson<Soldiers>("{\"items\":" + File.ReadAllText(Path.Combine(folder, "final_population.json")) + "}").items;
        string army = sourceSpecies;
        if (string.IsNullOrEmpty(army))
            army = all.GroupBy(s => s.species).OrderByDescending(g => g.Average(s => s.gen)).ThenBy(g => g.Key, StringComparer.Ordinal).First().Key;
        var evolved = all.Where(s => s.species == army && s.gen >= 1).OrderBy(s => s.genome[0], StringComparer.Ordinal).ToList();
        if (evolved.Count == 0) throw new InvalidOperationException($"{sourceRun}: no living '{army}' soldier born in the run");
        var wanted = new HashSet<string>(evolved.Select(s => s.genome[0]));

        var vectors = new Dictionary<string, float[]>();                       // only the wanted lines are parsed
        foreach (var line in File.ReadLines(Path.Combine(folder, "vectors.jsonl")))
        {
            int a = line.IndexOf("\"id\": \"", StringComparison.Ordinal) + 7, b = a > 6 ? line.IndexOf('"', a) : -1;
            if (b > a && wanted.Contains(line.Substring(a, b - a))) { var v = JsonUtility.FromJson<Vector>(line); vectors[v.id] = v.values; }
        }
        var load = new Dictionary<string, float>();                            // parents come before their children in the file
        foreach (var line in File.ReadLines(Path.Combine(folder, "alleles.jsonl")))
        {
            var r = JsonUtility.FromJson<AlleleRow>(line);
            float p1 = r.parent_id != null && load.TryGetValue(r.parent_id, out var x) ? x : 0f;
            float p2 = r.parent2_id != null && load.TryGetValue(r.parent2_id, out var y) ? y : p1;
            load[r.id] = !string.IsNullOrEmpty(r.parent2_id) ? (p1 + p2) / 2f : p1 + (r.@operator != null && r.@operator.StartsWith("nn-") ? 1f : 0f);
        }
        float k = mutationsOverride >= 0f ? mutationsOverride : (float)evolved.Average(s => load.TryGetValue(s.genome[0], out var l) ? l : 0f);

        var standard = base.FounderPool;
        int n = Math.Min(evolved.Count, standard.Count / 2);
        var rng = World.Random.For(Species, "garden");
        var order = Enumerable.Range(0, standard.Count).ToArray();
        for (int i = 0; i < n * 2; i++) { int j = rng.Range(i, order.Length); (order[i], order[j]) = (order[j], order[i]); }

        var pool = new List<FounderAllele>();
        for (int i = 0; i < n; i++)
        {
            var w = vectors[evolved[i].genome[0]];
            if (w.Length != Layout.VectorLength) throw new InvalidOperationException($"{sourceRun}: {w.Length} weights, the layout needs {Layout.VectorLength}");
            pool.Add(new FounderAllele(AlleleValue.OfVector(w), "evolved"));
        }
        for (int i = 0; i < n; i++) pool.Add(new FounderAllele(standard[order[i]].Value, "founder"));
        var mutation = Species.GetComponentInChildren<NeuralMutation>(true);
        for (int i = 0; i < n; i++)
        {
            var value = standard[order[n + i]].Value;
            int times = (int)k + (rng.Chance(k - (int)k) ? 1 : 0);
            for (int t = 0; t < times; t++)
            {
                var job = mutation.StartMutation(this, new Allele(LocusId, 0, value, "founder"), rng);
                if (job.Succeeded) value = job.Result;
            }
            pool.Add(new FounderAllele(value, "drifted"));
        }
        Summary = $"garden of {Species.Id}: {n} per group from {sourceRun} army {army}, k = {k:0.##} mutations";
        Debug.Log("GardenNeuralGenomeGene: " + Summary);
        return pool;
    }
}
