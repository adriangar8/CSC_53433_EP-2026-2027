# Conventions

For humans and AI agents working in this repo.

## EvoSim rules

- All randomness goes through `RandomStream`, never `UnityEngine.Random` or the clock, so runs replay from their seed.
- No fitness function. The brain only returns action probabilities.
- Per-animal state lives in stats or traits, not in module fields.
- New modules go in `Assets/Student` (`Student.asmdef`). Start from `Assets > Create > EvoSim > Script` or the recipes in `Docs/Interface/22-extending-recipes.md`. They must pass their conformance tests (Test Runner, EditMode).
- The terrain under `TerrainGround` must not change during a run (the walkable grid is built once).

## Unity

- Don't hand-edit `.unity` / `.prefab` YAML unless there is no other way. Prefer editor scripts or scene builders (example: `Assets/Student/Editor/AlarmCallsScene.cs`).
- Let Unity create `.meta` files and commit them with their asset.
- Only one person edits a given scene at a time, and says so.
- Unity MCP: follow `Docs/Kingdoms/UNITY-MCP.md`; never edit or save shared scenes through the MCP.

## Git

- One branch per task, from up-to-date `master`. Small commits.
- Pull request or a heads-up before merging.
- Never commit secrets, API keys, personal logins or `Library/`.

## Runs

- Outputs go in `Logs/EvoSim/runs/<name>-s<seed>/`.
- Keep the runs and `Library/EvoSim/AnswerCache` you care about (runs replay with `-cache`).
- Heavy runs on the school machines only 18h–8h and on weekends.
