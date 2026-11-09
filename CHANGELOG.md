# Changelog

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
