# Unity MCP (optional): let Claude Code drive the Unity Editor

Status: macOS: verified end to end on 2026-11-25 (Unity 6000.3.9f1, Claude Code 2.1.294, uv 0.12.10). Windows: not yet verified (Prakhar: date and result here).

[MCP for Unity](https://github.com/CoplayDev/unity-mcp) lets Claude Code drive the open Unity Editor: read the Console,
inspect the hierarchy, enter Play mode, run tests, recompile, take screenshots. **Optional: nobody has to use it.**

Not using it? Nothing to do. You may see `MCP-FOR-UNITY` lines in the Console; ignore them.

## Rules

- Use it to **inspect and check**. Scene edits through the MCP only in scratch scenes, never `Kingdoms.unity` or any other
  shared scene. Real scene changes go through code (scene builders).
- One Claude Code session per Unity editor.
- Keep the `scripting_ext` (`execute_code`) and `asset_gen` tool groups **off**.

## What's in the repo

- The package, pinned at **v10.3.0** in `Packages/manifest.json` (Unity fetches it from git).
- `Assets/Student/Editor/McpTeamDefaults.cs`: on editor load, if you have no value yet, sets `MCPForUnity.AutoRegisterEnabled`
  = false and `MCPForUnity.TelemetryDisabled` = true, and logs one line. Existing values are never changed. Why: the
  package's startup rewrite silently edits AI-client configs and re-registers Claude Code without the telemetry opt-out.

## Prerequisites

- Claude Code.
- `uv` (it downloads a suitable Python by itself):
  - macOS: `curl -LsSf https://astral.sh/uv/install.sh | sh`
  - Windows: `powershell -ExecutionPolicy ByPass -c "irm https://astral.sh/uv/install.ps1 | iex"`
- `git` on PATH.

## Register once per machine

From the repo root (the server name goes **before** `-e`):

```
claude mcp add UnityMCP --scope local --transport stdio -e DISABLE_TELEMETRY=true -- uvx --from mcpforunityserver==10.3.0 mcp-for-unity --transport stdio
```

`--scope local` stores it in `~/.claude.json` for this project path only: nothing in the repo, nothing for other projects.
Windows: if `uvx` is not found, use the full path from `where uvx` instead of `uvx`.

In Unity: **Window > MCP for Unity > Toggle MCP Window** (Cmd/Ctrl+Shift+M) > **Connect** tab > Connection > transport
**stdio**. **Never click Configure/Register for Claude Code**: it would rewrite the registration without the telemetry opt-out.

## Verify

1. `claude mcp get UnityMCP` shows `DISABLE_TELEMETRY=true` and `10.3.0`.
2. In Claude Code, `/mcp` shows UnityMCP connected. Ask it to read the Console.
3. Telemetry: **Window > MCP for Unity > Edit EditorPrefs** shows `MCPForUnity.TelemetryDisabled` = true.

## Daily use

- Tests need the `testing` group: ask Claude to run `manage_tools activate testing`.
- Run **filtered** tests through the MCP, with an **empty, unsaved scene** open (test runs can leave objects in the open scene).
- Run the **full EditMode suite by hand** in the Test Runner. Via the MCP it took 12 min, a poll timed out, and
  `ScriptTemplatesCompile` / `StubsCompile` failed only in that run.
- The MCP cannot discard scene changes, and Unity won't switch scenes while one is dirty.
- `create_script` won't overwrite an existing file: edit files normally.

## Upgrading

Change the tag in `Packages/manifest.json` **and** the version in the registration, same version for everyone:

```
claude mcp remove UnityMCP -s local
claude mcp add UnityMCP --scope local --transport stdio -e DISABLE_TELEMETRY=true -- uvx --from mcpforunityserver==<new version> mcp-for-unity --transport stdio
```

## Troubleshooting

| Symptom | Fix |
|---|---|
| macOS: Claude or `uv` not found by Unity | Unity launched from the Hub doesn't get the shell PATH. Set the Claude/uv paths in the MCP window, or launch the Hub from Terminal |
| `Port 64xx not released yet` / `falling back to port 64xx` warnings after Play mode or a recompile | Harmless: the bridge moves to the next port and the server follows it |
| One call times out | Retry once |
| `ScriptTemplatesCompile` / `StubsCompile` fail through the MCP | Rerun them in the Test Runner |
| `RegressionTests.PinnedHashes` (Lab1_Small/1234/scripted-prey) fails | Already fails on master, unrelated to the MCP |
| Another AI client (Cursor, Codex...) got a `UnityMCP` entry before the defaults applied | Delete that entry from its config |

## Remove

```
claude mcp remove UnityMCP -s local
```
