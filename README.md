# RoCiv

A Roblox real-time grand strategy game inspired by Civilization and Humankind, built in tested phases.

**Current state:** Phases 1–3 are complete and tested in Roblox Studio:
- the procedural map with fog of war
- territory interaction and ownership with test civilizations
- movement regions with server-side pathfinding

Next up is Phase 4 (simulation clock and match framework).

- [docs/PHASE1_REPORT.md](docs/PHASE1_REPORT.md): original Phase 1 build and tests
- [docs/PHASE1_FIXES_REPORT.md](docs/PHASE1_FIXES_REPORT.md): map size, camera, backdrop, fog-of-war foundation
- [docs/PHASE2_3_REPORT.md](docs/PHASE2_3_REPORT.md): civilizations and ownership, tile design, chat layout, movement regions and pathfinding

## Layout

```
src/shared/          -> ReplicatedStorage.RoCiv.Shared            (config, terrain defs, geometry, point lookup)
src/server/          -> ServerScriptService.RoCiv                 (MapService network layer)
src/server/Map/      -> ServerScriptService.RoCiv.Map             (MapGenerator, MapValidator, MovementGraph, Pathfinding)
src/server/Systems/  -> ServerScriptService.RoCiv.Systems         (CivilizationSystem, TerritorySystem, VisibilitySystem)
src/client/          -> StarterPlayer.StarterPlayerScripts.RoCiv  (ClientMain, state, renderer, camera, selection, movement, UI)
tools/StudioSync.lua -> dev helper: pulls src/ from a GitHub commit into the open place
```

`default.project.json` maps these folders for [Rojo](https://rojo.space/).

## Running

Open `RoCiv.rbxl` in Roblox Studio and press **Play**. The server generates and validates a 260-territory map and its movement graph, and the camera frames the whole map.

| Input | Action |
|---|---|
| Left-click | Select a territory (its neighbours are outlined) |
| Right-click (no drag) / × | Deselect |
| Right-drag | Pan |
| WASD / arrow keys | Pan |
| Mouse wheel | Zoom toward the cursor |
| F | Frame the whole map |

Chat sits small in the top-right corner. In Studio only, the red **DEV ONLY** panel (top-left) has these tools:
- Regenerate the map with any seed and territory count.
- Fog: reveal all, add vision at the selected territory, remove all vision.
- Ownership: give the selected territory to test civilization A / B / C or none, with live territory lists.
- Movement: region overlay, route tool (click a start, then a goal), Land/Naval, range preview with an MP budget, and a test road along the current route.
- Overlay of territory ids and neighbour links.

All tunables live in `src/shared/MapConfig.luau`.
