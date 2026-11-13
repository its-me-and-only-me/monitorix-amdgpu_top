# Changelog

## v1.4.3 — 2026-11-11

- **Text mode for `when=<n>hour` views:** the CGI's `when` regex accepts any
  numeric prefix (`4hour`…), but it only sets `tf->{res,tc,tb,ts}` for
  day/week/month/year — the text table then failed with an empty
  `--resolution=`. The module falls back to 5-minute rows over `<n>` hours
  (the built-in modules share this latent limitation).
- Screenshots in `docs/screenshots/` refreshed: the graph view now shows the
  livelier last-4-hours timeframe (`when=4hour`), as dark- and light-theme
  variants (`graphs-4hour-dark.png` / `graphs-4hour-light.png`).

## v1.4.2 — 2026-11-11

- **Memory panel: capacity totals are dashed reference lines now.** The
  filled AREA backdrops (v1.4/v1.4.1) read as a "blue block" covering the
  plot — GTT total (host memory) spans nearly the whole Y range. VRAM/GTT
  total are now thin dashed lines (`LINE1` + rrdtool `dashes`) in neutral
  colors that work on both themes; the module also supports the `dashes`
  suffix in panel style strings generally. The theme-detection code of
  v1.4.1 became moot and was removed.

## v1.4.1 — 2026-11-11

- **Theme-adaptive capacity backdrops:** the Memory panel's VRAM/GTT total
  AREA colors are light by design — on the **black theme** the restored
  backdrops (see v1.4) buried the graph under a white wall. They are now
  mapped to dark variants (`#33334D` GTT, `#4D4D4D` VRAM) whenever the
  theme background is dark, and stay light on light themes.

## v1.4 — 2026-11-11

Follow-ups to the upstream feedback (mikaku/Monitorix issue #489):

- **RRDtool version comparison (issue #488):** the CGI now compares
  `$RRDs::VERSION` via `version->declare(...)->numify`, exactly like the
  built-in modules since 3.16.x. The previous numeric comparison broke on
  two-digit versions (RRDtool 1.10 would have selected the ancient
  `graph()` interface and lost `--full-size-mode`).
- **Column balancing:** the two table columns (3 main-size graphs left,
  small graphs right) are now measured after drawing and the main graphs
  are redrawn so both columns end at the same height — the grey margins
  above/below the left column are gone. The left cell is top-aligned
  (`td-valign-top`) as well.
- **Memory panel backdrops really drawn:** the style regex expected
  `AREA#color` but the panel definitions use `AREA:#color`, so the VRAM/GTT
  capacity backdrops had silently degraded to normal lines since the
  beginning. Fixed — both capacity areas are visible now.
- **Robustness:** the theme colour list is guarded (`|| []`) so a caller
  that hasn't initialised `graph_colors` (e.g. early index generation) no
  longer takes down the whole module render.

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
