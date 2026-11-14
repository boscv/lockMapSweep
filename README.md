# 🗺️ lockMapSweep

**A smarter destination sweep for OpenKore's `randomWalk`.**

While the character is on the configured `lockMap`, the plugin divides the walkable area into blocks and visits valid destinations in an orderly way.

## ✨ How it works

- Uses the walkable area reachable from the character's current position and ignores disconnected islands.
- Divides that area's bounds into configurable blocks and selects valid destinations in the current block.
- Respects OpenKore's `lockMap_x`, `lockMap_y`, `lockMap_randX`, and `lockMap_randY` settings. These restrict destinations; other walkable cells may still be used along the route.
- Avoids repeating destinations during a block's visit quota and prefers adjacent blocks that have not been visited yet.
- When changing blocks, searches for a destination reachable through the source and destination blocks.
- Advances progress only after the route ends and the character's position confirms arrival. Interrupted or failed routes do not count as visits.
- Updates the plan when the map or relevant settings change. If a changed restriction invalidates an active plugin route, that route is cleared and replanned.

## ⚙️ Configuration

Add these options to OpenKore's `control/config.txt`:

| Option | Default | Description |
| --- | --- | --- |
| `lockMapSweep_enabled` | `0` | Set to `1` to enable the plugin. |
| `lockMapSweep_blocksX` | `2` | Number of blocks horizontally. |
| `lockMapSweep_blocksY` | `2` | Number of blocks vertically. |
| `lockMapSweep_cellsPerBlock` | `3` | Successful visits before moving on. Blocks with fewer valid destinations use a smaller quota. |
| `lockMapSweep_useStateFile` | `1` | Save the plan and progress. Set to `0` to disable persistence. |
| `lockMapSweep_stateDir` | `plugins/lockMapSweep/state` | Directory for state files. |

The plugin also respects OpenKore's existing `lockMap` and coordinate restriction settings.

Example: a 3×3 sweep with up to two visits per block.

```text
lockMapSweep_enabled 1
lockMapSweep_blocksX 3
lockMapSweep_blocksY 3
lockMapSweep_cellsPerBlock 2
lockMapSweep_useStateFile 1
```

![3×3 grid on ra_fild12](https://github.com/user-attachments/assets/eaca470e-e85f-4090-b76b-8d58f0654b21)

*Example grid for `ra_fild12`.*

## 💾 Saved state

With persistence enabled, the plugin saves progress, used and failed destinations, and the pending route. On startup, it checks the saved state against the current map geometry, block settings, and coordinate restrictions. Older or incompatible files are rebuilt. State writes replace the file atomically so a failed write preserves the previous valid state.

## ⌨️ Commands

- `lockMapSweep status` — show whether the plan is ready, the current map, block and visit counts, and blocks visited in the current cycle.
- `lockMapSweep rebuild` — build a fresh plan from the current map and settings. If rebuilding fails, the previous valid state is preserved.
- `lockMapSweep clearstate` — delete the saved file without changing the in-memory plan. State is created again on the next `rebuild` or restart.
