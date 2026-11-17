# 🗺️ lockMapSweep

**Smarter map exploration for [OpenKore](https://github.com/OpenKore/openkore)**

**Version 2.1.0** · **English** | [Português](README.pt-BR.md)

OpenKore's `randomWalk` moves your character, but random destinations do not necessarily spread exploration across a map. **lockMapSweep** organizes destination selection: it divides navigable ground into blocks, recognizes obstacles and connected regions, remembers which areas still need visits, and considers travel costs when choosing where to go next.

**The plugin decides *where* to explore; OpenKore calculates and executes *how* to get there.** It is not a fixed patrol route or a replacement for combat, NPC, or general navigation features.

## Quick start

1. Place `lockMapSweep.pl` in your OpenKore plugin directory.
2. Configure `lockMap` and normal `randomWalk` behavior in `control/config.txt`.
3. Add the following options for a **3 × 3 grid** and **2 coverage destinations per block per round**:

   ```text
   lockMapSweep_enabled 1
   lockMapSweep_blocksX 3
   lockMapSweep_blocksY 3
   lockMapSweep_cellsPerBlock 2
   lockMapSweep_useStateFile 1
   ```

4. Launch OpenKore and enter `lockMapSweep status` to inspect the current plan.



## Three concepts to know

| Concept | Meaning |
| --- | --- |
| **Block** | A section of the configured grid. Each block has a coverage-visit quota per round. |
| **Region** | A connected area inside a block. Walls or other obstacles can split one block into multiple regions. |
| **Coverage visit** | A confirmed arrival at a destination deliberately selected for coverage. Only this counts toward the block quota. |

A **round** finishes once the applicable block quotas have been met. For example, four blocks with a quota of two visits each call for up to eight confirmed coverage arrivals, subject to the valid destinations available in each block.

**Visits to a block do not have to be consecutive.** If the character leaves before fulfilling that block's quota, confirmed progress is preserved and can be completed after a later return.

**Passing through an area is not automatically a coverage visit.** The character may cross a corridor, an intermediate region, or a finished block simply to reach another destination. That movement is **transit** and does not increment visit counts.

## Visual examples: from simple to complex maps

These illustrations show possible planner decisions, not guaranteed patrol patterns. Dashed lines explain the idea of movement, not the exact path the game will execute. Numbered points indicate an example sequence, not a mandatory order.

### 1. Open map: avoid needless crossings

![Open 2×2 grid with a geographically coherent example of adjacent block visits](docs/images/01-simple-block-coverage.svg)

With **four blocks** and `lockMapSweep_cellsPerBlock 2`, each block has up to two coverage visits per round. On an open map, one coherent illustrative order is **1 → 2 → 3 → 4 → 8 → 7 → 6 → 5**: after point 4, the character is near the lower-right block and need not cross the entire grid to point 5.

The plugin considers travel costs, pending quotas, and regional history, so **this exact order is not guaranteed**. The example shows why adjacent opportunities may make more sense than unnecessary cross-map trips.

### 2. Fragmented map: two regions inside one block

![Two regions separated by a wall within the same block, connected through a lower block](docs/images/02-fragmented-connected-regions.svg)

A wall separates **A** and **B** within the upper block. To move from A to B, the character must first travel through **C** in the lower block and approach from the other side.

- The plugin treats A and B as separate regions even though they share a block.
- It considers transit through C when planning access to B.
- If C is only used for transit, **C receives no coverage credit**.

**Why it helps:** a block boundary does not trick the planner into assuming every part of that block is directly connected. This is how it handles irregular, fragmented maps.

### 3. Costly detours: deferring can be more efficient

![A nearby coverage destination is selected before another reachable target requiring a long detour](docs/images/03-avoid-costly-detours.svg)

Imagine two outstanding coverage destinations: **A** is nearby, while **B** lies behind an obstacle. B remains reachable through a longer corridor, but pursuing it right now would require a substantial detour.

- The planner considers **travel cost**, not just straight-line distance on the map.
- It may choose A first and keep B pending, without manufacturing an arrival.
- B may become an option later when planning conditions are more favorable. **There is no guarantee that every deferred obligation will be serviced quickly or within any particular round.**

**Why it helps:** coverage does not become a series of expensive detours solely to follow a rigid order. The drawn paths are illustrative, not a guarantee of the precise native route.

### 4. Unequal regions: balance opportunities over time

![Illustrative regions with 60%, 30%, and 10% of eligible destination cells](docs/images/04-proportional-regions.svg)

Suppose regions **A**, **B**, and **C** contain 60%, 30%, and 10% of eligible destinations. Larger regions generally offer more opportunities, but the plugin also considers confirmed-visit history to give relatively neglected regions more attention.

This **does not** prescribe six visits to A, three to B, and one to C out of every ten. Selection is probabilistic, depends on available paths, and varies across rounds.

**Why it helps:** small corners remain part of the planning process rather than disappearing behind much larger areas.

### 5. Failed destination: continue and retry promptly

![A failed route can be followed by another available destination immediately, while repeated retries use a progressive 1–8 second delay](docs/images/05-failure-cooldown-retry.svg)

An interrupted or unsuccessful route **does not count as a visit**. A failed destination should not block other available choices.

- **Another usable destination exists:** the planner may choose it at the next opportunity without a global pause.
- **A failed destination must be retried:** the minimum delay increases through **1s → 2s → 4s → 8s**, capped at eight seconds for consecutive failures. OpenKore's actual scheduling may take longer.
- **All options are temporarily unavailable:** quotas stay pending; retries are throttled without running expensive searches or routing loops on every AI tick.
- **A route remains impossible:** failure is never credited as a successful visit.

Progressive backoff avoids repeated unsuccessful routes without delaying usable alternatives.

### 6. Strategic transit through an already completed block

![Travel from A to a pending destination in C through completed block B, without another visit to B](docs/images/06-transit-through-completed-block.svg)

The character has an outstanding coverage destination in **C**, but the available corridor crosses block **B**, whose quota is already complete (`2/2`).

- The planner can cross B even though its coverage quota is fulfilled.
- **Crossing B is transit:** it does not add a third visit to B.
- A visit is credited only after a confirmed arrival at the selected destination in C.

**Why it helps:** completed blocks are not forbidden zones. The character can still use connected corridors to reach outstanding destinations elsewhere.

## How does it choose the next destination?

The planner follows this process:

1. **Find walkable ground.** Use OpenKore movement rules to identify the component connected to the character and exclude unreachable islands.
2. **Build blocks and regions.** Create the block grid and detect areas separated by obstacles within those blocks.
3. **Check outstanding visits.** Consult each block's confirmed count and available destinations for the current round.
4. **Compare travel opportunities.** Consider nearby regions, arrival and continuation costs, history, and outstanding coverage. Strategic transit waypoints can help approach distant regions.
5. **Ask OpenKore to route.** OpenKore uses its normal navigation system to execute movement.
6. **Update after the outcome.** A confirmed coverage arrival counts; transit and failed routes do not. The plan can be reconsidered as the character moves.

The planner **does not follow a fixed block order** or guarantee the globally shortest route. It can defer a connected region when the optional detour would be too costly.

### What counts as a visit?

| Event | Counts? |
| --- | :---: |
| Confirmed arrival at the selected coverage destination | ✅ |
| Passing through an intermediate block, corridor, or region | ❌ |
| Reaching a strategic transit waypoint | ❌ |
| Queuing a route that has not finished | ❌ |
| An interrupted or failed route | ❌ |
| Standing still on the only eligible destination | ❌ |

## Configuration

| Option | Default | Purpose |
| --- | --- | --- |
| `lockMapSweep_enabled` | `0` | Set to `1` to enable the plugin. |
| `lockMapSweep_blocksX` | `2` | Number of blocks across the map. |
| `lockMapSweep_blocksY` | `2` | Number of blocks vertically. |
| `lockMapSweep_cellsPerBlock` | `3` | Maximum confirmed coverage visits per block per round. Blocks with fewer eligible destinations may have lower quotas. |
| `lockMapSweep_useStateFile` | `1` | `1` persists progress between runs; `0` keeps it only in memory. |
| `lockMapSweep_stateDir` | `plugins/lockMapSweep/state` | Saved-state directory. |

### Working with `lockMap`

The plugin respects `lockMap`, `lockMap_x`, `lockMap_y`, `lockMap_randX`, `lockMap_randY`, and destinations excluded through OpenKore's `add_dropDestinationCells` hook.

These settings restrict **where a coverage visit may end**, not every walkable cell the character can travel through. This is why a route can cross other blocks or corridors, and temporary staging may leave the destination-restricted area without enlarging the set of valid coverage targets.

The plugin is active only while enabled and the character is on the configured `lockMap`. It does not set the map for you, teleport, or replace unrelated OpenKore behavior.

## Console commands

| Command | Effect |
| --- | --- |
| `lockMapSweep status` | Shows the map, planning state, current block, and visit counters. |
| `lockMapSweep rebuild` | Rebuilds the plan using current map data and settings. If rebuilding fails, the previous valid in-memory plan is retained, although incompatible settings can pause exploration. |
| `lockMapSweep clearstate` | Deletes the saved state file **without immediately resetting** the in-memory plan. A later state write may recreate the file. |

## Saved progress and special situations

With `lockMapSweep_useStateFile 1`, the plugin can restore confirmed block visits, regional history, outstanding quotas, failed destinations, and pending routes. In exceptionally narrow configurations, it can also preserve internal movement-recovery phases.

On startup it checks that the saved state matches the current map and settings. Incompatible or invalid state is rebuilt instead of being trusted. Changes to geometry, the grid, or destination restrictions can therefore restart recorded progress.

**Why might the character stop choosing destinations?** Failed routes may be waiting for their retry window, a reachable region may require a detour considered too costly at the moment, or a very restrictive configuration may leave no useful coverage destination. In some situations OpenKore can still use ordinary `randomWalk` as a fallback; during explicitly blocked recovery states the plugin suppresses that fallback to avoid uncontrolled movement.

**Extreme configuration:** if only one destination cell is allowed, the plugin may need to move away and return before crediting another confirmed arrival. That prevents stationary credit, but it is not meaningful exploration of a larger area. For useful coverage, configure an area with multiple walkable destinations.

**What it does not promise:** visiting every cell, distributing exactly equal visits among regions, reaching physically disconnected areas, or completing routes that OpenKore and the game server cannot execute.

## Changelog

### 2.1.0 — Global region-aware planning

- Blocks can contain **multiple separately connected regions**, including regions reachable only by traveling through another block.
- Exploration no longer requires finishing a block before moving on: **partial visit quotas remain pending** and may be resumed later.
- Destination selection now considers **proportional regional history**, travel costs, and **strategic transit** across the map.
- Saved progress includes the information needed to resume **quotas, regional history, pending routes, and route-failure recovery**.
- Failed destinations are reconsidered with **progressive 1–8 second retries**, without counting attempts as visits.
- Prevented stationary visit credit in one-destination configurations; a new arrival must correspond to actual movement.

### 2.0.0 — Block navigation and confirmed arrivals

- Configurable map blocks and walkable destination selection.
- Progress counts only **confirmed arrivals**, not route requests.
- Destination restrictions, responses to map/configuration changes, and basic recovery from interrupted routes.
- Saved-state compatibility checks and safer file replacement.

---

*lockMapSweep organizes exploration destinations. OpenKore and the game server remain responsible for executing movement.*
