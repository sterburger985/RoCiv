# RoCiv

A Roblox real-time grand strategy game inspired by Civilization and Humankind, built in tested phases.

**Current state:** Phase 1 (procedural map foundation) is complete. See [docs/PHASE1_REPORT.md](docs/PHASE1_REPORT.md).

## Layout

```
src/shared/   -> ReplicatedStorage.RoCiv.Shared        (config, terrain defs, geometry, point lookup)
src/server/   -> ServerScriptService.RoCiv             (MapService script, Map/MapGenerator, Map/MapValidator)
src/client/   -> StarterPlayer.StarterPlayerScripts.RoCiv (ClientMain, renderer, camera, selection, UI)
```

`default.project.json` maps these folders for [Rojo](https://rojo.space/).

## Running

Open `RoCiv.rbxl` in Roblox Studio and press **Play**. The server generates and validates a 150-territory map and prints the report to Output.

- Left-click a territory to select it; right-click or × to deselect.
- WASD / arrow keys pan, mouse wheel zooms, right-drag pans.
- In Studio only, the red **DEV ONLY** panel regenerates the map with any seed and territory count.

All tunables live in `src/shared/MapConfig.luau`.
