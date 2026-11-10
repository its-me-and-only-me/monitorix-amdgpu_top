# Changelog

## v1.3 — 2026-11-10

Code review follow-ups (see `docs/testlog.md` for the verification runs):

- **Timeout guard:** every `amdgpu_top` invocation (daemon and CGI info block)
  now runs under a hard timeout — new option `cmd_timeout` (default 30 s). A
  wedged GPU/driver can no longer stall the whole Monitorix update loop; the
  child is killed and `U` values are written. New robustness scenario `g)`.
- **Negative temperatures:** temperature DS (`t_*`, `gm_t_*`) are created with
  minimum `U` instead of `0`; existing RRDs migrate in place via
  `rrdtool tune --minimum <ds>:U` (no data loss).
- **imagetag IDs:** multihost image selection now uses the built-in group
  convention (`$e2` = 1-based group number, anchored match) instead of the
  previous group+panel sum, which collided across groups.
- **Memory panel:** the larger capacity backdrop (GTT total) is drawn first so
  the smaller VRAM backdrop stays visible.
- **CGI hygiene:** the invalid-panel warning goes into the page output instead
  of calling `logger()` (which would print into the HTTP response).
- **Config friendliness:** `<list>` accepts `0,1` (no space after comma);
  single-quoted device indices are stripped like double-quoted ones.
- **Tests now test the shipped module:** `parse_test.pl` calls the real
  `amdgpu_top.pm` (the duplicate `lib/AmdgpuTopParser.pm` was removed); all
  harnesses load the module from the repository, not from `/usr/lib/monitorix`.
- **Zoom legend:** the legend height adjustment now applies to zoom images too.
- **Info block** honours `<map>` display names; removed unused imports.
- Documentation: option defaults corrected (`use_nan_for_missing_data`,
  `show_current_values`, `show_info` default to `n`; the drop-in sets `y`),
  `<desc>` and `cmd_timeout` documented, the excluded-fields list completed,
  troubleshooting section added, soft hyphens removed from `docs/testlog.md`.

## v1.2 — 2026-11-09

- No module changes; publication preparation: GPL headers with author
  attribution, LICENSE (GPL-2.0 full text), English README (German version at
  `docs/README.de.md`), this changelog, WebUI screenshots.

## v1.1 — 2026-11-09

- Layout: 3 large panels on the left (GPU usage, Power, Memory usage),
  7 small panels on the right; `<graphs>` titles follow the new order.
- Fully replaces the built-in `amdgpu` module: drop-in overrides `graph_name`
  (`amdgpu` → `amdgpu_top`, exact old menu position) and disables `amdgpu`
  via `<graph_enable>`.
- New `panels` option (CGI-only): hide permanently empty panels without
  losing history — all 79 data sources keep being recorded. Drop-in ships
  `panels = 1, 2, 3, 4, 5, 6, 7` (gfx1151: voltage/fan/media sensors are
  hardwired 0 or `null`).
- Two-pass panel rendering (AREA backgrounds first, then lines) so the
  memory panel's `gtt_tot` AREA no longer buries the VRAM lines.
- `t_cgi.pl` derives expected panel/image counts from the configuration.

## v1.0 — 2026-11-09

Initial release: complete Monitorix module for `amdgpu_top -J -n 1` JSON output.

- Parser for the full JSON document; 79 RRD data sources per device slot
  (gpu_activity, GRBM, GRBM2, Sensors, CPU frequencies, VRAM/GTT,
  gpu_metrics, fdinfo); temps ÷100 → °C, power ÷1000 → W.
- `_init` with RRD creation and `.bak` rotation on schema change;
  collects a probe document before creating the RRD (aborts on a broken
  data source instead of destroying existing data).
- 10 graph panels + text-mode value table + static device info block
  (`amdgpu_top -J --dump`, best-effort).
- Options: `cmd`, `no_pc`, `use_nan_for_missing_data`, `show_current_values`,
  `show_info`, `file`, `<map>`, `rigid`/`limit`.
- Test harnesses (`parse_test.pl`, `t_update.pl`, `t_cgi.pl`, `t_robust.pl`)
  incl. 10 robustness scenarios; results in `docs/testlog.md`.
