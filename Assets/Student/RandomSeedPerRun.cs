using System;
using System.Text.RegularExpressions;
using EvoSim;
using UnityEngine;
#if UNITY_EDITOR
using UnityEditor;
#endif

/// <summary>
/// Gives every Play-mode run of the Kingdoms scene a new seed, and names its run folder after it
/// (<c>economy-s1234</c>), so each run is logged under its own seed.
/// </summary>
/// <remarks>
/// <para><b>Mechanism.</b> Listens to <see cref="World.Configuring"/>, which every World raises in Awake before the run
/// exists. Nothing is added to the scene.</para>
/// <para><b>Seed.</b> With <c>Tools ▸ Kingdoms ▸ Random Seed Per Run</c> checked (the default), a seed between 1 and
/// 99 999 is drawn; unchecked, the seed set on the World is kept, to replay a run.</para>
/// <para><b>Run name.</b> Always set: the recorder's name without its seed suffix (<c>economy-s1</c> gives
/// <c>economy</c>), then <c>-s{seed}</c>. The recorder fills in the seed, and adds <c>-2</c>, <c>-3</c>… when the folder
/// exists already.</para>
/// </remarks>
public static class RandomSeedPerRun
{
    /// <summary>The scenes this applies to.</summary>
    static readonly string[] Scenes = { "Kingdoms" };

    const string PrefKey = "Student.RandomSeedPerRun";

    /// <summary>On by default; the menu item turns it off (saved per machine, in the editor's preferences).</summary>
    static bool Enabled
    {
#if UNITY_EDITOR
        get => EditorPrefs.GetBool(PrefKey, true);
        set => EditorPrefs.SetBool(PrefKey, value);
#else
        get => true;
        set { }
#endif
    }

    [RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.SubsystemRegistration)]
    static void Install()
    {
        World.Configuring -= Configure;     // domain reload may be off: never subscribe twice
        World.Configuring += Configure;
    }

    static void Configure(World world)
    {
        if (Array.IndexOf(Scenes, world.gameObject.scene.name) < 0) return;

        if (Enabled) world.Seed = new System.Random().Next(1, 100000);

        var recorder = world.GetComponentInChildren<RunRecorder>(true);
        if (recorder != null)
        {
            string baseName = Regex.Replace(recorder.RunName ?? "", @"-s(\d+|\{seed\})$", "");
            if (baseName.Length == 0) baseName = "{world}";
            recorder.RunName = baseName + "-s{seed}";
        }

        Debug.Log($"[RandomSeedPerRun] {world.gameObject.scene.name}: seed {world.Seed}" +
                  (Enabled ? " (new)" : " (kept from the World)") +
                  (recorder != null ? $", run folder {recorder.RunName.Replace("{seed}", world.Seed.ToString())}" : ""));
    }

#if UNITY_EDITOR
    const string MenuPath = "Tools/Kingdoms/Random Seed Per Run";

    [MenuItem(MenuPath)]
    static void Toggle() => Enabled = !Enabled;

    [MenuItem(MenuPath, true)]
    static bool ToggleValidate()
    {
        Menu.SetChecked(MenuPath, Enabled);
        return true;
    }
#endif
}
