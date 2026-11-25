using UnityEditor;
using UnityEngine;

/// <summary>
/// Team defaults for MCP for Unity: auto-register off, telemetry off. Keys that already exist are never changed.
/// </summary>
/// <remarks>
/// The package's StartupConfigRewrite (scheduled with delayCall) silently edits AI-client configs and re-registers
/// Claude Code without the telemetry opt-out. This constructor runs earlier in the same domain load. It only uses
/// EditorPrefs, so it compiles with or without the package.
/// </remarks>
[InitializeOnLoad]
public static class McpTeamDefaults
{
    const string AutoRegisterKey = "MCPForUnity.AutoRegisterEnabled";
    const string TelemetryDisabledKey = "MCPForUnity.TelemetryDisabled";

    static McpTeamDefaults()
    {
        bool changed = false;
        if (!EditorPrefs.HasKey(AutoRegisterKey))
        {
            EditorPrefs.SetBool(AutoRegisterKey, false);
            changed = true;
        }
        if (!EditorPrefs.HasKey(TelemetryDisabledKey))
        {
            EditorPrefs.SetBool(TelemetryDisabledKey, true);
            changed = true;
        }
        if (changed)
            Debug.Log("Kingdoms: MCP for Unity team defaults applied (auto-register off, telemetry off)");
    }
}
