# RoCiv

A Roblox real-time grand strategy game inspired by Civilization and Humankind, built in tested phases.

**Current state:** Phase 1 (procedural map foundation) is complete, including fixes for map size, camera framing, the world backdrop and a server-side fog-of-war foundation, plus the Phase 2 territory-interaction items (ownership display, hover and selection, info panel, debug overlay).

- [docs/PHASE1_REPORT.md](docs/PHASE1_REPORT.md): original Phase 1 build and tests
- [docs/PHASE1_FIXES_REPORT.md](docs/PHASE1_FIXES_REPORT.md): root causes, fixes, fog of war, tests, performance, limitations

## Layout

```
src/shared/          -> ReplicatedStorage.RoCiv.Shared            (config, terrain defs, geometry, point lookup)
src/server/          -> ServerScriptService.RoCiv                 (MapService network layer)
src/server/Map/      -> ServerScriptService.RoCiv.Map             (MapGenerator, MapValidator)
src/server/Systems/  -> ServerScriptService.RoCiv.Systems         (TerritorySystem, VisibilitySystem)
src/client/          -> StarterPlayer.StarterPlayerScripts.RoCiv  (ClientMain, state, renderer, camera, selection, UI)
```

`default.project.json` maps these folders for [Rojo](https://rojo.space/).

## Running

Open `RoCiv.rbxl` in Roblox Studio and press **Play**. The server generates and validates a 260-territory map, and the camera frames the whole map in your window.

| Input | Action |
|---|---|
| Left-click | Select a territory |
| Right-click (no drag) / × | Deselect |
| Right-drag | Pan |
| WASD / arrow keys | Pan |
| Mouse wheel | Zoom toward the cursor |
| F | Frame the whole map |

In Studio only, the red **DEV ONLY** panel has these tools:
- Regenerate the map with any seed and territory count.
- Toggle reveal-all, add vision at the selected territory, or remove all vision.
- Set owners (placeholder civilizations 1–8).
- Show territory ids and neighbour links.

All tunables live in `src/shared/MapConfig.luau`.
