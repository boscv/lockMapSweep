# 🗺️ lockMapSweep

**Smarter map exploration for [OpenKore](https://github.com/OpenKore/openkore).**  
**Version 2.0.0**

**🌐 Language:** **English** | [🇧🇷 Português](README.pt-BR.md)

## What is lockMapSweep?

OpenKore can move a character around a map using `randomWalk`, but random destinations do not necessarily provide organized coverage. **lockMapSweep plans exploration across the walkable part of your configured `lockMap`:** it keeps the existing grid of smaller areas (**blocks**), identifies connected regions inside them, and chooses destinations while accounting for the remaining block quotas across the map.

Think of it as keeping a map-wide list of places still owed a visit, then taking useful opportunities as routes unfold. It remains a random-walk destination planner; it does not prescribe a fixed patrol.

**Good to know:** lockMapSweep changes **where random walking tries to go**. OpenKore still handles pathfinding and actual movement. The plugin is active only while the character is on the configured `lockMap` and it is enabled.

## How it works

1. **Build the map topology.** The plugin finds walkable cells connected to the character under OpenKore's movement rules, keeps the configured block grid, and identifies internally disconnected regions within each block. Regions that are not connected to the character's navigable area do not create visit obligations.
2. **Keep round quotas.** `lockMapSweep_cellsPerBlock` is the maximum number of confirmed destination visits assigned to each block in a round. Visits to one block may be separated by exploration elsewhere; leaving a block does not complete or reset its quota.
3. **Choose proportionally.** Eligible destination cells determine each region's area share. Confirmed region history adjusts probabilistic selection over multiple rounds, so small regions can gain priority when neglected without receiving a guaranteed per-round allocation.
4. **Plan travel globally.** Bounded lookahead considers remaining quotas, arrival and departure costs, and connected regions across neighboring blocks. A distant obligation can be approached through strategic transit waypoints. Transit does not count as a visit, and the plan is recalculated as the character moves or conditions change.
5. **Use convenient opportunities.** Coverage history can favor a region when it is nearby or fits a useful continuation. A region requiring excessive extra travel can be deferred until a suitable opportunity; it may remain deferred indefinitely rather than force a detour.
6. **Confirm each visit.** A block quota and region history advance only after the character reaches an intentionally selected coverage destination and the arrival is confirmed. Transit, queued routes, interrupted routes, and failed routes do not add visits.

OpenKore still calculates and executes each route. The plugin's topology and cost estimates guide destination planning; they do not guarantee that OpenKore's native route will match an estimated path or succeed. Relevant map and configuration changes invalidate or rebuild affected planning state.

## Getting started

1. Install `lockMapSweep.pl` in the plugin directory used by your OpenKore installation, and make sure OpenKore loads it.
2. Set a `lockMap` and enable/configure OpenKore's normal random-walking behavior in `control/config.txt`.
3. Add the lockMapSweep settings below and set `lockMapSweep_enabled 1`.
4. Start OpenKore and type `lockMapSweep status` in its console to check the current plan.

> The plugin does not teleport the character, choose a `lockMap` for you, or replace OpenKore's general navigation, combat, and NPC movement.

### Example configuration

Add these lines to OpenKore's `control/config.txt` (and configure your usual `lockMap`/randomWalk settings separately):

```text
lockMapSweep_enabled 1
lockMapSweep_blocksX 3
lockMapSweep_blocksY 3
lockMapSweep_cellsPerBlock 2
lockMapSweep_useStateFile 1
```

This example creates a **3 × 3 grid** and aims for **up to two confirmed destination visits per block**.

![Example 3×3 block grid on ra_fild12](https://github.com/user-attachments/assets/eaca470e-e85f-4090-b76b-8d58f0654b21)

*Illustrative 3 × 3 grid on `ra_fild12`. Actual block boundaries depend on the walkable area.*

## Settings reference

| Setting | Default | What it does |
| --- | --- | --- |
| `lockMapSweep_enabled` | `0` | Set to `1` to activate the plugin. |
| `lockMapSweep_blocksX` | `2` | Number of blocks across the map. |
| `lockMapSweep_blocksY` | `2` | Number of blocks from top to bottom. |
| `lockMapSweep_cellsPerBlock` | `3` | Maximum confirmed coverage-destination visits assigned to each block per global round. Visits may be non-consecutive. A block with fewer eligible destinations may have a smaller quota. |
| `lockMapSweep_useStateFile` | `1` | Set to `1` to save progress to disk or `0` to keep it only in memory. |
| `lockMapSweep_stateDir` | `plugins/lockMapSweep/state` | Directory used for saved state files. |

### Interaction with OpenKore settings

The plugin respects the existing `lockMap`, `lockMap_x`, `lockMap_y`, `lockMap_randX`, and `lockMap_randY` settings. These coordinate settings restrict **eligible destinations**, not every walkable cell along the route. It also takes destination exclusions registered through OpenKore's `add_dropDestinationCells` hook into account.

**Technical detail:** A coverage target must be connected to the character's current navigable area and pass the configured destination restrictions. Other walkable cells can be used as intermediate travel, including cells in blocks whose quotas are already complete. The planner uses movement-rule connectivity and bounded route-cost searches, while OpenKore independently executes the selected route; server behavior, obstacles, or route failures can change the actual movement.

## Console commands

| Command | What happens |
| --- | --- |
| `lockMapSweep status` | Displays whether the plan is ready, the current map, block and visit counts, and blocks already visited in this cycle. |
| `lockMapSweep rebuild` | Rebuilds the plan using current map data and settings. If rebuilding fails, the previous valid in-memory plan is preserved; incompatible live settings may still pause sweep navigation. |
| `lockMapSweep clearstate` | Deletes the saved state file without clearing the current in-memory plan. A later state write can create the file again. |

## Saving progress and recovering from problems

With state-file saving enabled, lockMapSweep stores confirmed block visits for the current round, long-term region visit history, deferred obligations, visited and failed destinations, and any pending target. Pending routes are reconciled after restart so a confirmed arrival is not counted twice. At startup, saved data is checked against the map geometry, grid, quota, and destination restrictions. **Incompatible state is discarded and rebuilt** rather than used for invalid navigation; changing those settings can therefore start a fresh coverage round and region-history baseline.

State files are written through a temporary file and replaced atomically to reduce the risk of a partially written save.

If an active plugin-owned route becomes invalid after a relevant configuration change, the plugin can cancel and recalculate it. If no valid plan can be built under the new configuration, it pauses its sweep instead of knowingly following stale constraints. Globally connected obligations can remain deferred when they exceed the bounded optional-detour policy; there is no promise that every deferred region will be serviced promptly. In other situations, where an otherwise ready plan cannot select a destination, OpenKore's normal random-walk fallback may still be used.

## Compatibility and planning limits

- lockMapSweep uses OpenKore's plugin hooks, `Field` walkability/movement rules, and native `randomWalk` routing. Install it in an OpenKore version that provides these interfaces and the map field data for the configured map.
- The planner uses probabilistic region selection and bounded lookahead. Coverage ratios are long-term tendencies, not fixed schedules or guarantees for a single round.
- Optional coverage detours are bounded. Strategic transit can take multiple native routes, but route estimates are not promises about server-confirmed movement.
- A region that is not globally reachable from the character's connected map area is not a coverage obligation. A reachable region may remain deferred if it is consistently too expensive to visit.
- Repeated travel through a block or corridor can be necessary for an efficient plan. Transit does not consume a block's visit quota, and a round does not require returning to its starting position.

No additional configuration is required for region-aware planning. The settings above retain the existing block grid, destination restrictions, and persistence controls.

---

*lockMapSweep organizes random-walk destinations on the configured lock map. OpenKore and the game server still determine whether movement is possible and how it is executed.*
