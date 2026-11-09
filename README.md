# Monitorix-Modul `amdgpu_top`

Monitorix-Modul, das **alle Messwerte der JSON-Ausgabe des
[`amdgpu_top`](https://github.com/Umio-Yasuno/amdgpu_top)-Tools** (eine Zeile bei
`amdgpu_top -J -n 1`) erfasst und in 10 Panels (Graph-Modus) bzw. einer
Wertetabelle + Geräteinfo-Block (Text-Modus) darstellt — inklusive GRBM-/GRBM2-
Engine-Auslastung, `gpu_metrics`-Telemetrie und fdinfo-Nutzungsdaten, die das
eingebaute `amdgpu`-Sysfs-Modul nicht bietet.

Getestet mit Monitorix 3.16.0, Perl ≥ 5.36 (nur Core-Module: `JSON::PP`, `RRDs`),
`amdgpu_top` v0.10.5 und einer Radeon 8060S (gfx1151 APU). Funktioniert für mehrere
Geräte und Gruppen (bis 8 Geräte pro Gruppe).

## Installation

```sh
# 1. Modul
sudo cp amdgpu_top.pm /usr/lib/monitorix/amdgpu_top.pm

# 2. Konfiguration als Drop-in (Hauptkonfiguration bleibt unverändert)
sudo cp config/99-amdgpu_top.conf /etc/monitorix/conf.d/99-amdgpu_top.conf

# 3. Dienst neu starten (übernimmt conf.d und lädt das Modul)
sudo systemctl restart monitorix
```

Das Modul registriert sich über `additional_graph_name` im Drop-in und erscheint im
WebUI-Menü. Die CGI-URL lautet
`monitorix.cgi?mode=localhost&graph=amdgpu_top&when=day&color=white`.

Voraussetzungen: `amdgpu_top` im `PATH` des Daemons (oder absoluter Pfad in `cmd`);
der CGI-Lauf (User `nobody`) braucht den Aufruf nur für den optionalen Info-Block
(`show_info`) — scheitert er dort stillschweigend, zeigt der Textmodus den Block einfach nicht.

## Konfiguration (Drop-in, Abschnitt `<amdgpu_top>`)

| Option | Default | Bedeutung |
|---|---|---|
| `<list>` | – | Gruppen → Gerätelisten, Index in die JSON-`devices[]`, z. B. `0 = 0` bzw. `0 = 0, 1` für zwei Geräte in einer Gruppe. |
| `cmd` | `amdgpu_top -J -n 1` | Aufruf im One-Shot-Modus (terminiert selbst nach ~1 s, kein `timeout`-Wrapper nötig). Absoluter Pfad möglich. |
| `no_pc` | `n` | `y` → zusätzlich `--no-pc` anhängen (GRBM/GRBM2 entfallen dann in den Quellen und erscheinen als Lücken/0). |
| `use_nan_for_missing_data` | `y` | `y` → fehlende Sensorwerte als NaN (Lücke im Graph); `n` → als 0. |
| `show_current_values` | `y` | Kurzwert-Legende (Current) in den kleinen Panels 8–10. |
| `show_info` | `y` | Statischer Geräte-Info-Block im Textmodus (best-effort via `amdgpu_top -J --dump`). |
| `file` | – | JSON aus Datei lesen statt Kommando (nur für Tests/Dry-Run). |
| `<map>` | – | Anzeigename je Geräteindex, z. B. `0 = Radeon 8060S`. |
| `rigid` / `limit` | – | Monitorix-Standard (`y,u,l` je Panel, Achsengrenzen). |

Panel-Titel kommen aus `<graphs>` (`_amdgpu_top1` … `_amdgpu_top10`), der
Modultitel aus `<graph_title>` — beides bereits im Drop-in enthalten.
Andere im Drop-in gesetzte globale Optionen (`show_gaps`, `global_zoom`,
`enable_zoom`, `temperature_scale`, `rrdtool_extra_options`) wirken wie üblich.

## Panels

1. GPU usage (%) · 2. GRBM engines (%) · 3. GRBM2 engines (%) · 4. Temperatures (°C) ·
5. Clocks (MHz) · 6. Power (W) · 7. Memory usage (MiB) · 8. Voltage (mV) ·
9. Fan speed (%) · 10. Media engine usage (%)

Panels 1–5 links, 6–10 rechts; Panels 1–7 in `main`-Größe mit
Current/Average/Min/Max-Legende, 8–10 in `small`-Größe.

## RRD-Schema (79 Datenquellen pro Geräteslot, Präfix `e<Gruppe>d<Slot>_`)

| Bereich | DS-Suffixe | Umrechnung |
|---|---|---|
| gpu_activity (3) | `act_gfx`, `act_media`, `act_mem` | – |
| GRBM (8) | `g_pipe`, `t_pipe`, `prim_asm`, `sh_export`, `sh_interp`, `color_blk`, `depth_blk`, `geom_eng` | – |
| GRBM2 (9) | `cp_gfx`, `cp_comp`, `cp_fetch`, `eff_arb`, `ring_ctrl`, `sdma`, `tex_cache`, `rb_memif`, `utc_l2` | – |
| Sensors Temp (10) | `t_edge`, `t_junc`, `t_mem`, `t_tctl`, `t_edg_crit`, `t_jnc_crit`, `t_mem_crit`, `t_edg_emer`, `t_jnc_emer`, `t_mem_emer` | – |
| Sensors Power (3) | `p_avg`, `p_input`, `p_gfx` | – |
| Sensors Clocks (2) | `sclk`, `mclk` | – |
| Sensors Voltage (2) | `vddgfx`, `vddnb` | – |
| Sensors Fan/PCIe (2) | `fan`, `pcie_lsp` | – |
| CPU-Frequenzen (2) | `cpu_favg`, `cpu_fmax` | Mittel/Max über Kerne |
| VRAM/GTT (4) | `vram_tot`, `vram_use`, `gtt_tot`, `gtt_use` | – |
| gpu_metrics (21) | `gm_t_*` (6 + Kern-Mittel `gm_t_core`), `gm_a*clk` (6), `gm_p_*` (4), `gm_v_*` (3), `gm_fan_pwm` | Temperaturen ÷100 → °C, Leistungen ÷1000 → W |
| fdinfo (13) | `fd_cpu`, `fd_comp`, `fd_dma`, `fd_dec`, `fd_enc`, `fd_gfx`, `fd_media`, `fd_jpeg`, `fd_vcn`, `fd_vpe`, `fd_vram`, `fd_gtt`, `proc_count` | `proc_count` = Anzahl Prozesse |

**Achtung Schemaänderungen:** jede Änderung der `@DSPEC`-Liste im Modul erzeugt ein
neues RRD — das alte wird automatisch nach `amdgpu_top.rrd.bak` gerettet und die
Historie beginnt neu (Konvention anderer Monitorix-Module).

## Bewusst nicht abgebildet

- Statische Info-Felder (ASIC, VBIOS, CU-Anzahl …) → nur im Textmodus-Info-Block
- `PCI Power State`, `Power Profile` (Strings, keine Messwerte)
- `current_*`- und `average_core_power`-Arrays von `gpu_metrics`
  (Einheit/Aggregation undocumented; bei `cpu_favg/cpu_fmax` und `gm_t_core` wurde die
  Aggregation bewusst definiert, hier nicht)
- `xdna_fdinfo` (NPU-Auslastung; eigenes späteres Feature)
- Pro-PID-fdinfo-Details (dynamische PID-Liste → nur aggregierte `Total fdinfo`-Werte
  plus `proc_count`)

## Hinweis zur DS-Benennung

RRD erlaubt max. 19 Zeichen je DS-Namen; die Suffixe sind entsprechend verkürzt und
mit den GRBM2-JSON-Keys (Achtung: teils **Doppel-Leerzeichen** im Original) exakt
abgestimmt. Neue DS daher immer gegen `docs/plan.md` §2.2 und
`lib/AmdgpuTopParser.pm` prüfen.

## Tests

```sh
./parse_test.pl    # Parser gegen 3 JSON-Samples + Live-Ausgabe
./t_robust.pl      # Robustheit: kaputtes Tool, Sonderfälle, Schema-Rotation
./t_update.pl      # Update gegen RRD mit Exaktwertprüfung (~3 min)
./t_cgi.pl         # CGI-Funktion: Graph-/Textmodus, day/week
```

Ergebnisse protokolliert in `docs/testlog.md`.

## Dateistruktur

```
amdgpu_top.pm                  # das Monitorix-Modul (init/update/cgi, autark)
lib/AmdgpuTopParser.pm         # standalone Parser ( nur für parse_test.pl)
config/99-amdgpu_top.conf      # conf.d-Drop-in (installieren!)
t_update.pl t_cgi.pl t_robust.pl parse_test.pl   # Test-Harnesses
samples/                       # JSON-Samples (oneshot, nopc, dump)
docs/plan.md docs/environment.md docs/testlog.md # Auswertung/Plan/Protokoll
```
