# 🗺️ lockMapSweep plugin

Smart `randomWalk` override for `lockMap` using fixed map blocks.

## ✅ What it does

- Reads `lockMap` field geometry once on plugin initialization (or when `lockMap`/plugin config changes).
- Divides the map into configurable blocks (`blocksX * blocksY`) using only the bounding rectangle of reachable walkable cells (not total map size), reducing "empty/cut" blocks on irregular maps.
- For each randomWalk cycle, picks random walkable **reachable** target cells inside the current block.
- Targets are selected dynamically each cycle (not a prebuilt fixed route list).
- Visits `N` random cells in the same block (`cellsPerBlock`), then chooses the next block using an adjacency-first strategy (prefer unvisited neighbor blocks; fallback to nearest unvisited block).
- While inside a block cycle, avoids repeating the same target cell until changing block.
- For routes **inside the same block**, selected targets are validated so the path can be kept inside that block.
- For the first route when switching block, target is chosen from a constrained transition search that only uses previous+next blocks (it will not cut through a third block), reducing retries and stalls.
- Does not fully reprocess the map on map changes.

## ⚙️ Config keys

### `lockMapSweep_enabled` `0|1`
Enable plugin (default: disabled).

### `lockMapSweep_blocksX` `<int>`
Number of horizontal blocks. Default: `3`

### `lockMapSweep_blocksY` `<int>`
Number of vertical blocks. Default: `3`

### `lockMapSweep_cellsPerBlock` `<int>`
Number of target cells to visit in each block before moving to next one. Default: `2`

### `lockMapSweep_useStateFile` `0|1`
Persist block metadata + loop progress to a state file. Default: `1`

### `lockMapSweep_stateDir` `<path>`
Directory used for state files. Default: `plugins/lockMapSweep/state`

## 🧪 Example

#### 📄 config.txt
```txt
# 9 blocks (3x3), 2 routes per block
lockMapSweep_enabled 1
lockMapSweep_blocksX 3
lockMapSweep_blocksY 3
lockMapSweep_cellsPerBlock 2
lockMapSweep_useStateFile 1
```

## 📝 Notes

- Plugin only intercepts randomWalk while character is inside `lockMap`.
- Block traversal is cycle-based: it tries to cover all non-empty blocks before resetting the cycle, avoiding fixed linear order like `0->1->2->3...`.
- If `lockMap` is changed while running, plugin rebuilds plan for the new map.
- Disconnected/unreachable islands (e.g. map-corner artifacts) are ignored by filtering to the main reachable component.
- If it cannot pick a valid target, default randomWalk behavior is used as fallback.

## ⌨️ Commands

- `lockMapSweep status` — show current runtime state (current block/visit counters).
- `lockMapSweep rebuild` — force full state rebuild for current `lockMap` (also removes saved state file first).
- `lockMapSweep clearstate` — remove only the saved state file (next rebuild/restart regenerates it).
