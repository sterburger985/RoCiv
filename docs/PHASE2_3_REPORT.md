# RoCiv — Phase 2 Completion and Phase 3 Report

Tested in Roblox Studio (one client + server) on 16 Oct 2026. Builds on [PHASE1_FIXES_REPORT.md](PHASE1_FIXES_REPORT.md).

## Decisions recorded
- **Coast stays shallow water** next to land (Civilization convention). No change was needed.
- **Chat** is a small panel in the top-right corner (`ChatWindowConfiguration`: right/top alignment, 0.65 width, 0.5 height, text size 13). The dev panel moved to the top-left to make room.

## How this work was picked up
A session the night before had already written most of this (civilizations, ownership API, tile design, chat layout, movement regions and pathfinding). It was pushed as a WIP commit explicitly marked "untested", plus a `tools/StudioSync.lua` helper. Studio already held those exact scripts (checked file by file).

This session reviewed that code and finished the missing parts. It tested everything in Studio, fixed what the tests found, and merged to `main` only after the tests passed.

## Phase 2: Territory interaction and ownership (your brief)

| Requirement | Implementation | Tested |
|---|---|---|
| Civilization identity separate from player | `CivilizationSystem`: `civilizationId`, `displayName`, `color`, `controllerType` (Player/AI/None), `playerUserId`, `capitalCityId` (unset), `status`, `isTest`. Kept apart from territories: Player → controls → Civilization → owns → Territories. | Yes |
| Test civilizations | A blue, B red, C green (Studio only). Each tester controls the first free one. Unowned territories stay supported. | Yes |
| Single ownership write path | `TerritorySystem.assignOwner` / `clearOwner`; queries `getOwner`, `isUnowned`, `isOwnedBy`, `getTerritoriesOf`, `countOf`. The owner is stored as a civilization id, never a name or colour. | Yes |
| Ownership index stays correct | Index of civ → territory set, checked by `validateOwnership()` (one owner per territory, index matches data, owner civ exists). | Yes |
| Prepare for expansion (no claiming rules) | `isAdjacentToCivilization`, `getFrontier(civ, landOnly)`. No costs, settlers or claim buttons. | Yes |
| Ownership visuals | Owner tint on the fill (terrain still recognisable) plus an owner-coloured border. Unowned stays neutral. The selection highlight never changes the owner colour. | Yes |
| Fog compatibility | Owner only sent for visible territories; explored ones show the last-seen owner; unexplored shows nothing. | Yes |
| Selection | Click → stable id → highlight + panel; another click moves it; click off the map, right-click or × clears it. Selection never changes ownership or reveals fogged data. | Yes |
| Neighbour inspection | Direct neighbours get a temporary cyan outline that disappears when the selection changes, and their ids are listed in the panel. | Yes |
| Info panel | Sections: Territory (id, terrain, elevation, fertility, visibility), Ownership (civ name + colour chip, or "Unowned"), Geography (land/water, neighbour count + ids), Development (city "None", resources "None yet", move cost). Built once and updated in place. | Yes |
| Dev ownership testing | Dev panel: A / B / C / None buttons for the selected territory, plus each civ's live territory list and an ownership-valid check. Studio only, and re-validated on the server. | Yes |

## Tile design
- Each territory's colour is shaded slightly (deterministic per id), so neighbours with the same terrain stay distinguishable.
- Tiles have a small height by terrain: water sits lower, mountains higher.
- Every terrain now has a decoration:

| Terrain | Decoration |
|---|---|
| Forest | Tree clumps |
| Mountains | Snow-capped ridges with foothills |
| Tundra | Snow patches and sparse firs |
| Desert | Dunes |
| Plains | Farm-field strips |
| Grassland | Low bushes |
| Ocean | Wave marks |

- **Fog-safe:** height and decorations exist only for explored territories (the renderer check flags any leak). Explored territories fade decorations toward grey.
- **Cost:** about 2,950 decoration parts with the whole 260-territory map revealed, and still 60 fps.

## Phase 3: Movement regions and pathfinding

### Design
- **`MovementGraph`** (server) subdivides every strategic territory into about one movement region per 3,600 studs² (1–8 per territory). It uses a seeded Voronoi inside the territory polygon with 2 relaxation passes.
  - Each region belongs to exactly one territory and is never owned, so ownership and navigation stay separate.
  - Within a territory, two regions are adjacent if they share an edge of at least 2 studs.
  - Across territories, two regions are adjacent if their boundary segments overlap on the shared territory edge by at least 2 studs. This only happens between neighbouring territories.
  - Regions inherit terrain, cost and passability from their territory. `hasRoad` is a placeholder.
- **`Pathfinding`** (server):
  - A* routes and Dijkstra movement ranges.
  - Step cost = the cost of entering the next region (Mountains 3, Forest 2, others 1), halved on road regions.
  - Domains: **Land** can't enter water; **Naval** can't enter land. Embarking comes later.
- **Fog:** routes and ranges for a player use only that player's knowledge. Unexplored regions are treated as passable at cost 1 for every domain, so a preview never reveals hidden terrain. The client receives region geometry only (no terrain or cost).
- **Network:** `GetMovementGraph`, `RequestRoute`, `RequestRange`. The server validates inputs and rate-limits each player to 10 requests per second.
- **Client `MovementClient`:** dev tools for a region-border overlay, the route tool (click start, click goal), Land/Naval toggle, a movement-range preview with an MP budget, and **Road along route (test)**.

### Tests (all run in Studio)

| Test | Result |
|---|---|
| Graph validation on 24 maps (150/260/400/600 territories): parent territory, convex geometry, area coverage, symmetric links, links only between neighbouring territories, each territory internally connected, every territory border crossable, whole graph connected | **24/24 PASS** |
| 1,200 random routes (Land + Naval): A* cost equals Dijkstra, each step adjacent, costs add up, no domain violations | **0 failures** |
| Fault injection (self link, missing id, one-way link, wrong parent, isolated region) | All detected (16 problems reported). **Bug found:** the validator crashed on a missing id instead of reporting it. Fixed and re-tested. |
| Region payload contains geometry only | PASS (1,150 regions, no terrain or cost fields) |
| Long land route on a known map | PASS: cost 21, 18 steps, contiguous, no water |
| Land unit into water / naval route on water | Rejected / PASS (cost 20, 20 steps, water only) |
| Movement range within budget | PASS (36 regions within 3 MP) |
| Road placeholder | Cost 21 → 10.5 via the server API; 14 → 7 via the panel button with the road drawn |
| Fog: 8 hidden region pairs, land and naval | All answered "cost 1" for both domains; nothing revealed |
| Rate limit / malformed requests | 4 of 14 burst requests rejected; bad ids, domain and NaN budget rejected |
| Real mouse use: route tool on, click start + goal | Exactly the clicked regions, cost 14 / 14 steps; clicks went to the route tool, not selection |
| Regeneration | Route, range, roads cleared; region overlay redrawn for the new map; server roads reset |

### Phase 2 tests

| Test | Result |
|---|---|
| 3 test civs; tester controls civ A | PASS |
| Assign → A, change → B, remove | Data, client display and both civs' lists update correctly each time |
| Ownership index valid; unknown civ rejected | PASS |
| Frontier helper | PASS (5 candidate territories) |
| Owner change on a territory not currently visible | 0 updates sent to the client |
| Ownership leaves terrain and neighbours untouched | PASS |
| Real click on the owned territory | Panel: "Civilization C (test)" with a green chip, Land, 5 neighbours (ids listed), City None, Resources None yet; 5 neighbour outlines drawn |

## Performance (Studio, one client)
| Item | Measured |
|---|---|
| Movement graph build | 40 ms (150 territories → 664 regions), 69 ms (260 → 1,150), 103 ms (400 → 1,759), 180 ms (600 → 2,619) |
| Startup self-test (40 routes, A* vs Dijkstra) | ~49 ms |
| Client render, 260 territories | 610–825 ms on first load (was ~520 before decorations) |
| Fully revealed map | 5,161 map instances (2,949 decoration parts); 60 fps, worst frame 19 ms |

## Known limitations
1. **Studio rendering quirk:** when the Studio window loses focus (for example to another app on top), its 3D view can show a grey sky with the moon while the UI keeps updating. Clicking or scrolling in the viewport restores it. This is Studio throttling, not the game.
2. Movement costs are fixed per terrain. There are no rivers, embarking or zones of control yet, and vision isn't blocked by terrain.
3. Roads are a dev placeholder: they exist only on the server graph until the next map, and only the player who built them sees them drawn.
4. Range previews extend into unexplored areas at the assumed cost of 1 (deliberate, so hidden terrain isn't revealed).
5. Route and range previews are dev tools; real unit movement and timing arrive with the simulation clock (Phase 4) and units (Phase 9).
6. Not tested: several real clients at once, touch or gamepad.

## Recommendation
Phase 2 and Phase 3 are complete and tested. **Next: Phase 4, the simulation clock and match framework** (match state, simulation time, single-player pause/speed, shared multiplayer speed, era timing). Movement timing (seconds per movement point) should be set there, because routes already return costs.
