# RoCiv — Phase 1 Fixes + Phase 2 Interaction Report

Tested in Roblox Studio (playtest with one client + server) on 15 Oct 2026. Builds on [PHASE1_REPORT.md](PHASE1_REPORT.md).

## Root causes

| Issue | Root cause found by inspection |
|---|---|
| **Map too small** | The world was a fixed 1600×1000 studs and the camera started at a hard-coded height of 900 studs with no knowledge of the viewport. The map covered only the middle ~60% of the screen at any window size. |
| **Fog of war "glitchy, only on land"** | **No fog-of-war system existed** (it was planned for Phase 5). What looked like fog came from presentation: (1) Studio's default Atmosphere haze plus a stale grey frame Studio shows until the viewport is hovered; (2) overexposed lighting (Brightness 3, Bloom, specular) washing pale land colours (tundra, desert, plains) almost white while the ocean stayed saturated, so it looked like fog over land only; (3) the white fill of the old selection `Highlight`. |
| **Grey background** | Nothing existed outside the map rectangle, so the camera saw Roblox's empty sky and haze. While fixing it, a second cause appeared: Roblox parts are capped at **2048 studs per axis**, so the new border plate (2582 studs wide) was silently clipped and the sea showed through the borders near the map edge. |

## What changed

### Map size and camera (priority 1)
- `MapConfig.mapSizeFor(count)`: the world now scales with the territory count (`TERRITORY_AREA` = 16,000 studs² per territory, `MAP_ASPECT` = 1.6), so territories stay the same size as the map grows. You can still force a size with `FIXED_MAP_WIDTH` / `FIXED_MAP_HEIGHT`.
- The default went from 150 territories on 1600×1000 to **260 territories on 2580×1612** (1.7× the territories, 2.6× the area).
- `CameraController` rewritten:
  - It computes the lowest camera height at which all four map corners fit inside the real viewport, using the actual field of view, aspect ratio and pitch, with margins.
  - It re-centres the tilted view vertically.
  - It re-fits when the window is resized, unless the player has already moved the camera; the zoom-out limit is always updated.
  - Zoom is smoothed and keeps the point under the cursor fixed.
  - Zoom-out is capped at 1.2× the fitted height, and the focus is clamped to the map, so the map can never be lost.
  - **F** re-frames the whole map.
  - The camera update is bound after Roblox's default camera priority.

### Fog of war (priority 2): new foundation
- **Server `TerritorySystem`** owns the authoritative map and ownership, and fires an owner-changed event.
- **Server `VisibilitySystem`** stores Visible, Explored and Unexplored state per player.
  - Vision comes from sources (territory + range in neighbour hops), so land and water behave identically.
  - It recalculates only when a source, the map or reveal-all changes, never per frame.
  - It remembers the last owner each player saw.
  - Every player starts with one placeholder source on the land territory nearest the map centre (range 3), until cities and units exist.
- **`MapService`** builds a separate view for each player.
  - Every territory's geometry is sent, so fog can be drawn on the exact borders.
  - Terrain, elevation, fertility, resources and owner are sent only for territories that player has explored. The owner is live while the territory is visible and last-seen while it is only explored.
  - Changes go out as small per-player deltas with a map version and a sequence number.
- **Client `ClientMapState`** mirrors the server view. It ignores stale or duplicate deltas and buffers early ones during a reload.
- **Client `TerritoryStyle`** turns state into colour (presentation only):
  - Visible: full terrain colour.
  - Explored: terrain colour faded toward grey.
  - Unexplored: dark fog, close to the border colour.
- Fog is drawn by **recolouring the same territory parts**, so it always uses the same ids and geometry as the map. Only the changed territories are restyled, in a single frame.
- Map regeneration resets visibility on the server and rebuilds everything on the client.

### World presentation (priority 3)
- The surroundings are all decorative: never data, never selectable.
  - A dark frame marks the playable edge.
  - A 60,000-stud open-sea backdrop (one part, scaled with a `SpecialMesh`) fills the rest of the view.
  - The border plate and frame use the same scaling trick to get past the 2048-stud limit.
- The backdrop (dark navy) is clearly different from fog (charcoal) and from gameplay ocean (blue, with borders).
- Client lighting:
  - Haze, depth of field, bloom and sun rays are turned off.
  - The sun is overhead, brightness is 1.6, specular is off, and there's a small saturation boost.
  - Territories use `Plastic`.
  - The terrain palette was made a little richer.

### Phase 2 items included (your list + mine)
- Ownership: server `setOwner`, owner tint on the fill and an owner-coloured border, delivered only to players who can see the territory. Placeholder owners 1–8 until civilizations exist.
- Hover outline (thin, white).
- Stronger selection: a thick gold outline plus lightened fill, readable at every zoom. The old white-fill `Highlight` is gone.
- Richer info panel: visibility, terrain, elevation, fertility, resources (placeholder), neighbour count and ids, and owner with a colour chip (marked "last seen" when only explored). It shows "Unknown" for unexplored territories.
- Dev-only debug overlay: territory ids and neighbour links.
- Dev panel (Studio only, re-validated on the server): regenerate, random seed, reveal all, remove all vision, add vision at the selected territory with a range, set or clear the owner, and the overlay toggle. It also shows live fog counts.

## Files changed

New:
- `src/server/Systems/TerritorySystem.luau`
- `src/server/Systems/VisibilitySystem.luau`
- `src/client/ClientMapState.luau`
- `src/client/TerritoryStyle.luau`
- `src/client/DebugOverlay.luau`

Rewritten:
- `src/server/MapService.server.luau`
- `src/client/CameraController.luau`
- `src/client/SelectionController.luau`
- `src/client/TerritoryInfoPanel.luau`
- `src/client/DevMapPanel.luau`
- `src/client/ClientMain.client.luau`
- The public part of `src/client/MapRenderer.luau` (the wedge and EditableMesh backends are unchanged)

Edited:
- `src/shared/MapConfig.luau`
- `src/shared/TerrainTypes.luau` (palette)
- `src/shared/MapQuery.luau` (tolerance)
- `src/server/Map/MapGenerator.luau` (size from config; removed the old payload builder)
- `src/server/Map/MapValidator.luau` (tolerance)

## Bugs found and fixed during testing
1. **Validator tolerance at large sizes.** At 600 territories (a ~3900-stud world), 2 of 20 maps failed the shared-edge check. The cause is that `Vector2` stores 32-bit floats, so a vertex computed independently by two cells differs by ~1e-3 studs. The tolerance is now 0.01 studs in the validator and in the point lookup. Re-test: 48 of 48 maps passed (150, 260, 400 and 600 territories).
2. **Clipped border plate.** Described above; fixed by scaling parts past the 2048-stud limit.
3. **Colour checks.** Part colours are stored with 8 bits per channel, so exact colour comparisons failed after fog blending. Style colours are now quantised.
4. **Overlapping vision sources.** A range-5 source inside the range-3 start source revealed nothing extra, because all sources shared one visited set. Each source now gets its own. A regression test now compares the client's visible set against an independent BFS for 4 overlapping configurations: 4 of 4 match.

## Tests performed (all in Studio, results observed, not assumed)

| Area | Test | Result |
|---|---|---|
| Generator | 48 maps across 150/260/400/600 territories, full validator | 48/48 PASS |
| Map fill | Engine projection (`WorldToViewportPoint`) of the 4 corners after framing | 2092×1153 viewport: map spans **96% of width, 82–83% of height**, fully inside |
| Resolution | Window restored to 812×675 (aspect 1.20) → auto re-fit | Fully inside, 96% of width; re-maximise re-fits again |
| Zoom | 5 wheel notches out → capped at 2545 (= 1.2 × fit 2121); 14 notches in → height 425 | Cap works; territory under the cursor stayed the same (385 → 385) |
| Pan / reframe | W then D keys moved the camera; **F** restored the exact fitted view | PASS |
| Fog | Land visible, **water visible**, visible→explored keeps last-known terrain, explored→visible→explored, adjacent consistency (range 1 = source + all neighbours), no terrain/owner data for unexplored territories in the payload, client state == server state (counts + sequence) | 15/15 PASS |
| Flicker | Colour writes recorded on every part during a 220-territory reveal | 1,628 parts changed, **max 1 write per part** |
| Overlapping sources | Client visible set vs independent BFS, 4 configurations + clear-all | 5/5 PASS |
| Ownership | Owner change on a visible territory reaches the client + border; change on an unexplored territory sends **0 deltas**; revealed later → owner shown; explored-only → keeps "last seen" owner | PASS |
| Server validation | Bad args and an unknown territory rejected by the dev remote | PASS |
| Regeneration | 5 rapid back-to-back regenerations (overlay on) | 1 map folder, 1 FX folder, 1 overlay folder, 1 of each GUI; fog reset to start (V40 E0 U220); old owner borders gone |
| Selection | 6 real clicks compared with an independent raycast of the rendered parts; off-map click deselects; right-click deselects | All match. One click inside the Roblox chat window's area was swallowed by the chat (see limitations) |
| Render self-check | Renderer re-validates every visual after every delta | Always PASS; 0 server warnings/errors in the run |

## Performance (Studio playtest, one client; Studio caps at 60 fps)

| Territories | World (studs) | Server generate | Client render | Map instances | Frame rate |
|---|---|---|---|---|---|
| 260 (default) | 2580×1612 | 118–155 ms | 203–521 ms* | 2,219 (1,953 parts) | 60 fps, worst 18 ms |
| 400 | 3200×2000 | 254–315 ms | 316–326 ms | 3,453 (3,047 parts) | 60 fps, worst 18 ms |
| 600 | 3919×2449 | 573–675 ms | 500 ms | 5,187 (4,581 parts) | 60 fps, worst 19 ms |

\* 521 ms is the first render on join; later renders took ~200 ms. A fog update (4–220 territories) applied in 1–17 ms.

## Remaining limitations
1. **Roblox's default chat window** sits over the top-left of the map and swallows clicks inside it while it's shown. It should be moved, shrunk or made toggle-only when the real UI is built.
2. Vision sources are dev and placeholder only; real sources (cities, units, towers) come in later phases. Vision ignores terrain (mountains don't block sight yet).
3. Unexplored territories still reveal their **shape** and neighbour ids (needed to draw fog exactly on borders). Terrain, ownership and resources are hidden.
4. Outlines are fixed in world width, so they look thinner when fully zoomed out. The fill lightening compensates.
5. Every generated map is still one continent; edge cells are smaller; no lakes or rivers yet; Coast is water.
6. Not tested: multiple real clients at once (the per-player code paths exist but only one player was in the test), touch and gamepad, live servers, portrait or ultrawide windows (the fit maths handles any aspect, but only 1.81 and 1.20 were tested on screen).
7. Generation is synchronous on the server: ~0.6 s at 600 territories. Fine for now; it should yield or use Parallel Luau for larger maps.
8. Studio may show a stale frame until the play viewport is hovered (Studio behaviour, not the game).

## Recommendation
All Definition-of-Done items in the fixes brief were tested and pass. **Phase 1 is ready to close.** The Phase 2 interaction items (ownership, hover, stronger selection, richer panel, debug overlay) are in and tested.

Next step: Phase 3, movement regions and pathfinding. Before that, two small decisions are worth making:
- Whether Coast should stay water.
- Where the chat and dev panels should live in the final screen layout.
