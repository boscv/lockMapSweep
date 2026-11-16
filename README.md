# 🗺️ lockMapSweep

**Smarter map exploration for [OpenKore](https://github.com/OpenKore/openkore).**  
**Version 2.0.0**

**🌐 Language:** **English** | [🇧🇷 Português](README.pt-BR.md)

## What is lockMapSweep?

OpenKore can move a character around a map using `randomWalk`, but random destinations do not necessarily provide organized coverage. **lockMapSweep makes that exploration more systematic:** it divides the walkable part of your configured `lockMap` into smaller areas (**blocks**) and chooses destinations in each block before moving on.

Think of it as exploring a neighborhood one section at a time instead of constantly jumping between unrelated streets.

**Good to know:** lockMapSweep changes **where random walking tries to go**. OpenKore still handles pathfinding and actual movement. The plugin is active only while the character is on the configured `lockMap` and it is enabled.

## How it works

1. **Find accessible ground.** The plugin identifies walkable cells connected to the character's current location, ignoring isolated areas that cannot be reached.
2. **Create a grid.** That area is divided into a configurable number of horizontal and vertical blocks.
3. **Choose a destination.** The plugin picks a valid, reachable target inside the current block and avoids repeating destinations unnecessarily.
4. **Check the result.** A visit counts **only after arrival is confirmed**. A canceled, interrupted, or stuck route does not count as a completed visit.
5. **Move to the next block.** After enough successful visits, it prefers an unvisited neighboring block. Once active blocks have been explored, another cycle can begin.

Routes between blocks are checked for connectivity. The plugin also responds to relevant map or configuration changes instead of blindly continuing with an outdated plan.

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
| `lockMapSweep_cellsPerBlock` | `3` | Maximum confirmed visits in a block before switching. A block with fewer valid destinations may have a smaller quota. |
| `lockMapSweep_useStateFile` | `1` | Set to `1` to save progress to disk or `0` to keep it only in memory. |
| `lockMapSweep_stateDir` | `plugins/lockMapSweep/state` | Directory used for saved state files. |

### Interaction with OpenKore settings

The plugin respects the existing `lockMap`, `lockMap_x`, `lockMap_y`, `lockMap_randX`, and `lockMap_randY` settings. These coordinate settings restrict **eligible destinations**, not every walkable cell along the route. It also takes destination exclusions registered through OpenKore's `add_dropDestinationCells` hook into account.

**Technical detail:** A target must belong to the walkable area connected to the character and pass the configured destination restrictions. When moving between blocks, target selection checks a route through the source and destination blocks. This reduces avoidable failures but cannot guarantee that every route will succeed on every server.

## Console commands

| Command | What happens |
| --- | --- |
| `lockMapSweep status` | Displays whether the plan is ready, the current map, block and visit counts, and blocks already visited in this cycle. |
| `lockMapSweep rebuild` | Rebuilds the plan using current map data and settings. If rebuilding fails, the previous valid in-memory plan is preserved; incompatible live settings may still pause sweep navigation. |
| `lockMapSweep clearstate` | Deletes the saved state file without clearing the current in-memory plan. A later state write can create the file again. |

## Saving progress and recovering from problems

With state-file saving enabled, lockMapSweep stores the current plan and progress, visited and failed destinations, and any pending target. At startup, it checks saved data against the map geometry, grid configuration, and destination restrictions. **Older or incompatible saved states are rebuilt** rather than used blindly.

State files are written through a temporary file and replaced atomically to reduce the risk of a partially written save.

If an active plugin-owned route becomes invalid after a relevant configuration change, the plugin can cancel and recalculate it. If no valid plan can be built under the new configuration, it pauses its sweep instead of knowingly following stale constraints. In other situations, where an otherwise ready plan cannot select a destination, OpenKore's normal random-walk fallback may still be used.

## What's new in 2.0.0?

- **More accurate progress:** a destination counts only after confirmed arrival, not when a route is requested.
- **Better route recovery:** interrupted or stuck routes do not falsely advance the block visit counter; failed targets are tracked.
- **Safer destinations:** improved connectivity checks and respect for `lockMap` coordinate restrictions and destination exclusions.
- **Live updates:** navigation plans react to relevant configuration and map changes.
- **More reliable saves:** stronger validation of persisted state and safer file replacement.

---

*lockMapSweep organizes random-walk destinations on the configured lock map. OpenKore and the game server still determine whether movement is possible and how it is executed.*
