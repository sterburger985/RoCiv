# RoCiv — Phase 1 Report: Procedural Map Foundation

Status: **complete, tested in Roblox Studio** (playtest, one client + server), 15–16 Oct 2026.

## Implementation summary

| Location (Studio) | Repo file | Purpose |
|---|---|---|
| `ReplicatedStorage.RoCiv.Shared.MapConfig` | `src/shared/MapConfig.luau` | Every tunable: seed, territory count, map size, terrain thresholds, render backend, camera, dev-tool flag |
| `ReplicatedStorage.RoCiv.Shared.TerrainTypes` | `src/shared/TerrainTypes.luau` | 8 terrain definitions (colour, water flag, base fertility, placeholder move cost) |
| `ReplicatedStorage.RoCiv.Shared.Geometry` | `src/shared/Geometry.luau` | Polygon maths: half-plane clipping with edge tags, area, centroid, point-in-convex, inset |
| `ReplicatedStorage.RoCiv.Shared.MapQuery` | `src/shared/MapQuery.luau` | Grid-accelerated "which territory contains this point" |
| `ServerScriptService.RoCiv.Map.MapGenerator` | `src/server/Map/MapGenerator.luau` | Seeded Voronoi territories, adjacency, elevation, moisture, terrain, fingerprint, client payload |
| `ServerScriptService.RoCiv.Map.MapValidator` | `src/server/Map/MapValidator.luau` | Identity / geometry / adjacency / terrain / selection checks with id-level report |
| `ServerScriptService.RoCiv.MapService` (Script) | `src/server/MapService.server.luau` | Authoritative map owner; generates + validates on start; `GetMap` / `MapUpdated` remotes; Studio-only `DevRegenerate` |
| `StarterPlayerScripts.RoCiv.ClientMain` (LocalScript) | `src/client/ClientMain.client.luau` | Fetch → render → selection wiring; local lighting tweaks |
| `StarterPlayerScripts.RoCiv.MapRenderer` | `src/client/MapRenderer.luau` | Wedge renderer (default) + experimental EditableMesh backend; render validation |
| `StarterPlayerScripts.RoCiv.CameraController` | `src/client/CameraController.luau` | Strategy camera: WASD/arrows pan, wheel zoom, right-drag pan |
| `StarterPlayerScripts.RoCiv.SelectionController` | `src/client/SelectionController.luau` | Click → map coordinates → territory id; single reusable Highlight |
| `StarterPlayerScripts.RoCiv.TerritoryInfoPanel` | `src/client/TerritoryInfoPanel.luau` | Reusable info panel (id, terrain, elevation, fertility, neighbours, owner) |
| `StarterPlayerScripts.RoCiv.DevMapPanel` | `src/client/DevMapPanel.luau` | **DEV ONLY** regenerate panel (seed, count, random seed, timings, validation) |

Place changes outside scripts: `Players.CharacterAutoLoads = false` (strategy view has no avatar); the template `Baseplate` and `SpawnLocation` were moved (not deleted) to `ServerStorage.TemplateParked`.

`default.project.json` is a Rojo mapping of `src/` to the Studio locations above, so the repo can be synced with Rojo later. During Phase 1 the scripts were written into Studio directly and verified to be byte-identical to the repo files (length + checksum per script).

## Architecture

```
MapConfig ─┐
           ▼
   MapGenerator (server) ──► MapData (authoritative, plain tables, keyed by id)
           │                       │
           ▼                       ▼
   MapValidator ──► report     toClientPayload ──► Remotes.GetMap ──► ClientMain
                                                                       │
                       ┌───────────────────────────────────────────────┤
                       ▼                       ▼                       ▼
                 MapRenderer            MapQuery (data)        SelectionController
             (visuals, TerritoryId      point → id lookup      click → plane → map
              attribute only)                                  coords → MapQuery → id
                                                                       │
                                                               TerritoryInfoPanel
```

**Generation.** `Random.new(seed)` scatters N points; two Lloyd relaxation passes even out cell sizes; each Voronoi cell is computed by clipping the map rectangle with the perpendicular bisector to every nearby site (sorted by distance, with an early exit). This is O(n² log n) but runs in ~45 ms for 150 and ~120–170 ms for 300 territories, and it is much simpler and more robust than Delaunay + dual + clipping.

**Adjacency.** Every clipped edge is tagged with the site that produced it, so each polygon knows exactly which neighbour lies across each edge (0 = map boundary). Two territories are neighbours only if their shared edge is at least `MIN_SHARED_EDGE_LENGTH` (4 studs), which filters out corner touches. Links are kept only if both sides agree.

**Terrain.** Elevation = multi-octave `math.noise` with a seeded offset, minus an edge falloff, normalised to 0..1. Sea level is chosen by quantile (`LAND_FRACTION` = 55% land) so every seed gets a predictable land share. Territories touching the map edge are forced to water, inland water bodies are filled to land (no lakes yet), water touching land becomes **Coast** and the rest **Ocean**. The highest 8% of land become **Mountains**; high latitudes become **Tundra**; otherwise moisture noise (with a bonus next to water) picks **Desert / Plains / Grassland / Forest**. Fertility = terrain base + moisture term + small seeded jitter, clamped 0..1.

> Design choice to confirm: **Coast is shallow water** next to land (Civilization convention), not a land/beach terrain. It is a one-line change in `TerrainTypes` + the generator if you'd prefer coastal land.

**Territory record** (`MapGenerator.Territory`): `id`, `polygon` (CCW `Vector2` list), `neighbors` (sorted ids), `terrainType`, `elevation`, `fertility`, `resources = {}`, `ownerId = nil`, `cityId = nil`, `movementMetadata = {moveCost, passableByLand, isWater}`, plus `centroid`, `area`, `edgeNeighbors`, `moisture`, `latitude`, `isWater`. Ids are explicit stored values (1..N, assigned in seeded order); nothing uses colour, position or instance names as identity.

**Determinism.** `MapGenerator.fingerprint` hashes ids, terrain, elevation, fertility, polygon coordinates and neighbour lists. The same seed + settings reproduce the complete logical map. The rendered map is a pure function of that data, so it is reproduced too (the in-game regenerate test returned to the identical fingerprint and identical instance count). Note: changing any config value (e.g. tundra latitude) changes the map for a seed.

**Rendering.** Each polygon is shrunk inward by `BORDER_INSET` (1.25 studs) and drawn as a 2-stud slab; a dark base plate under the map shows through the gaps, which forms every border line with zero extra instances. Default backend: two `WedgePart`s per fan triangle. Each territory is one `Model` with a `TerritoryId` attribute. Ownership colouring later = `MapRenderer:setTerritoryColor(id, color)`.

**Selection.** The mouse ray is intersected with the map plane, converted to map coordinates and resolved by `MapQuery` against the polygon data — rendering never decides identity. One persistent `Highlight` is retargeted per selection. Deselect: left-click off the map, right-click without dragging, or the panel's × button.

**Server authority.** The generator lives in `ServerScriptService` so clients cannot regenerate hidden data (important for later fog of war / resources). Clients receive a payload copy without internal fields; the seed is only included in Studio. `DevRegenerate` is created only when `RunService:IsStudio()` and `DEV_TOOLS_ENABLED` are both true, and the handler re-checks `IsStudio()` and validates/clamps its arguments.

## Testing (all run in Roblox Studio)

| Test | Method | Result |
|---|---|---|
| Map generates, ~150 territories | Server start log | PASS — 150 territories, seed 12345 |
| Unique ids, required fields | Validator identity checks | PASS |
| Irregular shapes | Visual check (screenshots of playtest viewport) | PASS — irregular convex polygons |
| Same seed → same map | Fingerprint compared across 2 generations in Edit, and across server restarts + in-game regeneration | PASS (`c0ba8cf2` for seed 12345/150 every time) |
| Different seed → different map | Fingerprints for seeds 12345 / 999 / 7 / 111 / 222 / 333 / 444 / 42 / 2026 | PASS — all distinct |
| Geometry valid, in bounds, no gaps/overlaps | Convex/CCW check, bounds check, area sum = 1.000000 of map, shared-edge matching | PASS |
| Neighbours valid | Existence, no self, no duplicates, symmetric, **independent brute-force shared-border search** compared against the lists, whole-graph connectivity | PASS |
| Isolated territories detected | Fault injection (emptied a territory's links) | Detected: "Isolated territories" + "disconnected" errors with ids |
| Validator catches errors | Fault injection: self link, missing id, duplicate, bad terrain, elevation 1.5, one-way link, isolated cell, broken polygon | 18 errors reported, each with territory ids |
| Terrain rules | Water ⇔ elevation < sea level, Coast ⇔ water touching land, Mountains ⇔ land ≥ mountain level, ranges 0..1 | PASS |
| Bulk validation | 45 seeds × 150 + 15 seeds × 300 territories | 60/60 PASS, 0 warnings, every terrain type present in every map |
| Every territory rendered / matches data | `MapRenderer.validate` (count, TerritoryId, terrain attribute, colour, one map folder) | PASS at 150, 200 and 300 |
| Selection picks the right territory | 6 real mouse clicks; each compared with an independent raycast against the rendered parts under the cursor | 6/6 match; panel showed matching id + terrain |
| Panel updates / deselect | Click sequence; × button; click off-map; right-click | PASS. (Escape was tried first and dropped — Roblox reserves it for its menu.) |
| Regeneration cleanup | Dev panel button (seed 777 / 300) and 5 rapid back-to-back regenerations | PASS — 1 map folder, 1 Highlight, 1 of each GUI; workspace returned to exactly 1,253 descendants for the 150 map |
| Camera | Wheel zoom (height 900 → 792 per notch confirmed), close-up screenshot | PASS (WASD and right-drag were not exercised by automated input) |

## Performance

Measured in a Studio playtest on the author's PC (one client). Frame rate was sampled with `RenderStepped` over 3 s; Studio caps at 60 fps, so "60" means "no measurable cost", not headroom.

| Territories | Generate (server) | Validate | Render (client, wedges) | Map instances | Frame rate |
|---|---|---|---|---|---|
| 150 | 42–46 ms | 5 ms | 117–442 ms* | 1,246 (≈1,094 parts) | 60 fps, worst frame 18 ms |
| 200 | 80–87 ms | 8–10 ms | — | — | — |
| 300 | 123–169 ms | 10–17 ms | 202–217 ms | 2,538–2,562 (≈2,237 parts) | 60 fps, worst frame 19 ms |

\* The 442 ms figure is the first render right after joining; later renders of the same size took ~117 ms. Rendering yields every 25 territories so the client never freezes.

One reading of **15 fps at 300** was taken right after the Roblox menu had been opened and closed; re-measuring in the same session gave 60 fps with and without the map, so it was not caused by the map. It is reported here for honesty.

## Rendering investigation (why wedges, not EditableMesh)

`EditableMesh` was verified directly rather than assumed:

- It works in Edit mode and on the server (unlimited memory there).
- On the **client**, the memory budget allowed only **8** `EditableMesh` objects in this Studio playtest (empty or not, `FixedSize` or not); creation #9 failed with "reaching memory budget limits". One mesh can hold 60,000+ vertices, so the limit is per object, not per vertex.
- Published games must opt in to **"Allow Mesh / Image APIs"** (Roblox docs).

Because one mesh per territory is impossible within that budget, the default renderer is the proven two-wedge method. The EditableMesh backend is kept (config `RENDER_BACKEND = "EditableMesh"`) and stops trying after the first budget failure. A future optimisation is a few **chunked** meshes with per-face colours, which would fit the budget and drop the instance count to single digits.

## Known limitations

1. **Instance count** grows ~7–8 parts per territory (≈2,240 at 300). It is fine at these sizes; for much larger maps, chunked EditableMesh or merging per terrain should be revisited.
2. **Every map is a single continent** (land share is fixed by quantile and the edge falloff is centred). Continents / archipelagos / presets are future generator modes.
3. **Edge cells are smaller** than interior cells (a Lloyd relaxation artefact at the rectangle edge). They are always ocean, so gameplay impact is small.
4. **No lakes or rivers yet.** Inland water is converted to land. Coast is defined as water (see design choice above).
5. **Selection highlight is subtle** (light fill + thin outline); stronger highlighting and hover are Phase 2 items.
6. **Studio viewport quirk (not a game bug):** while the mouse is outside the Studio play viewport, Studio may keep showing a stale grey frame; the map appears as soon as the viewport is hovered. Regenerated maps showed immediately.
7. **Not tested:** multiple simultaneous clients, mobile/touch input, gamepad, live published servers, WASD/right-drag panning via automated input.
8. Generation is synchronous on the server (≤170 ms at 300). That is fine now; for much larger maps it should yield or run in Parallel Luau.
9. The dev panel's "random seed" uses `math.random` on the client — fine for a Studio tool, never used in gameplay.

## Phase 2 recommendation (not implemented)

**Territory Interaction**, built directly on this foundation:

1. A server `TerritorySystem` module that owns `MapData` (moved out of `MapService`) with read APIs and an ownership-change event.
2. Ownership data + colouring: `ownerId` changes on the server → compact delta remote → `MapRenderer:setTerritoryColor` (owner tint or border colour), without re-sending the map.
3. Better selection: hover highlight, stronger selected border (e.g. a drawn outline from the polygon), neighbour preview, and keyboard/gamepad-safe deselect.
4. A richer info panel (neighbour list, placeholder resources, owner name) and a debug overlay toggle for ids/adjacency lines.
5. Decide the Coast-as-water question and whether to add Lakes before movement regions (Phase 3) depend on them.
