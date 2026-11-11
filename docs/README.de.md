# Monitorix-Modul `amdgpu_top`

Monitorix-Modul, das die **vollständige Menge der numerischen Zeitreihen aus der
JSON-Ausgabe des [`amdgpu_top`](https://github.com/Umio-Yasuno/amdgpu_top)-Tools**
(`amdgpu_top -J -n 1`) erfasst — 79 Datenquellen pro Gerät, die wenigen bewusst
ausgenommenen Felder stehen unter „Bewusst nicht abgebildet" — und in bis zu 10
Panels (Graph-Modus, per `panels`-Option auswählbar) bzw. einer
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

Das Modul registriert sich über das `graph_name`-Override im Drop-in und erscheint im
WebUI-Menü. Die CGI-URL lautet
`monitorix.cgi?mode=localhost&graph=amdgpu_top&when=day&color=white`.

Voraussetzungen: `amdgpu_top` im `PATH` des Daemons (oder absoluter Pfad in `cmd`);
der CGI-Lauf (User `nobody`) braucht den Aufruf nur für den optionalen Info-Block
(`show_info`) — scheitert er dort stillschweigend, zeigt der Textmodus den Block einfach nicht.

## Konfiguration (Drop-in, Abschnitt `<amdgpu_top>`)

| Option | Default | Bedeutung |
|---|---|---|
| `<list>` | – | Gruppen → Gerätelisten, Index in die JSON-`devices[]`, z. B. `0 = 0` bzw. `0 = 0, 1` für zwei Geräte in einer Gruppe. |
| `cmd` | `amdgpu_top -J -n 1` | Aufruf im One-Shot-Modus (terminiert normalerweise nach ~1 s; abgesichert durch `cmd_timeout`). Absoluter Pfad möglich. |
| `no_pc` | `n` | `y` → zusätzlich `--no-pc` anhängen (GRBM/GRBM2 entfallen dann in den Quellen und erscheinen als Lücken/0). |
| `use_nan_for_missing_data` | `n` | `y` → fehlende Sensorwerte als NaN (Lücke im Graph); `n` → als 0. Das ausgelieferte Drop-in setzt `y`. |
| `cmd_timeout` | `30` | Harter Timeout (Sekunden) je `amdgpu_top`-Aufruf. Schützt den Monitorix-Update-Loop gegen aufhängende GPU/Treiber (das Tool spricht DRM-Ioctls direkt an und könnte unbegrenzt blockieren). |
| `panels` | alle 10 | Kommagetrennte Liste sichtbarer Panels (1-basiert). Ausgeblendete Panels werden **nur im WebUI weggelassen** — alle 79 Datenquellen bleiben weiter im RRD erhalten, ein Panel ist ohne Historienverlust reaktivierbar. |
| `show_current_values` | `n` | Kurzwert-Legende (Current) in den kleinen Panels. Das ausgelieferte Drop-in setzt `y`. |
| `show_info` | `n` | Statischer Geräte-Info-Block im Textmodus (best-effort via `amdgpu_top -J --dump`). Das ausgelieferte Drop-in setzt `y`. |
| `file` | – | JSON aus Datei lesen statt Kommando (nur für Tests/Dry-Run). |
| `<map>` | – | Anzeigename je Geräteindex, z. B. `0 = Radeon 8060S`. |
| `<desc>` | – | Optionale Gruppen-Beschreibung unterhalb der Graphen der Gruppe. |
| `rigid` / `limit` | – | Monitorix-Standard (`y,u,l` je Panel, Achsengrenzen). |

Panel-Titel kommen aus `<graphs>` (`_amdgpu_top1` … `_amdgpu_top10`), der
Modultitel aus `<graph_title>` — beides bereits im Drop-in enthalten.
Andere im Drop-in gesetzte globale Optionen (`show_gaps`, `global_zoom`,
`enable_zoom`, `temperature_scale`, `rrdtool_extra_options`) wirken wie üblich.

## Panels

Links (groß, mit Current/Average/Min/Max-Legende):
**1. GPU usage (%) · 2. Power (W) · 3. Memory usage (MiB)**

Rechts (klein, mit Kurzwert-Legende bei `show_current_values = y`):
**4. GRBM engines · 5. GRBM2 engines · 6. Temperatures (°C) · 7. Clocks (MHz) ·
8. Voltage (mV) · 9. Fan speed (%) · 10. Media engine usage (%)**

Das Memory-Panel zeichnet die Gesamtgrößen (VRAM/GTT total) als AREA-Hintergrund
und die Nutzlasten als Linien darüber; die Hintergrundfarben passen sich dem
Graph-Theme an (helle Farben auf hellen Themes, dunkle Varianten auf dem
Black-Theme).

Das Modul balanciert beide Spalten automatisch: Nach dem Zeichnen werden die
Graphen der linken Spalte so neu gerendert, dass beide Spalten auf der gleichen
Pixelhöhe enden (keine grauen Ränder mehr).

### Ausgeblendete Panels (`panels`-Option)

Im mitgelieferten Drop-in sind **Panels 8–10 deaktiviert** (`panels = 1, 2, 3, 4, 5,
6, 7`), weil sie auf dieser gfx1151-APU dauerhaft leer bleiben (8 h Live-Daten):

| Panel | Befund |
|---|---|
| 8 Voltage | `Sensors.{VDDGFX,VDDNB}` hart auf 0 verdrahtet; `gpu_metrics`-Spannungen `null` |
| 9 Fan speed | `Sensors.Fan` und `gpu_metrics.fan_pwm` `null` (firmwaregesteuert) |
| 10 Media engine | fdinfo-Media-Zähler `null`/konstant 0 (keine Media-Workload-Zähler) |

Die Datenquellen werden unverändert weiter aufgezeichnet. Reaktivierung: Panelnummer
zu `panels` hinzufügen und den zugehörigen `_amdgpu_topN`-Titel im Drop-in
entkommentieren — die vorhandene Historie ist dann sofort sichtbar.

## Ersetzung des eingebauten `amdgpu`-Moduls

Das Drop-in verdrängt das eingebaute `amdgpu`-Modul komplett:

- `<graph_enable> amdgpu = n` → Daemon sammelt keine `amdgpu`-Daten mehr,
  das Modul verschwindet aus dem WebUI-Menü
- `graph_name = …` (komplette Liste aus der Hauptconfig, mit `amdgpu` →
  `amdgpu_top` ersetzt) → `amdgpu_top` erscheint **an genau der alten
  `amdgpu`-Position** in Menü und „All graphs“-Seite

**Upgrade-Hinweis:** Die `graph_name`-Zeile im Drop-in kopiert die Default-Liste
der Hauptconfig. Nach einem Monitorix-Upgrade gegen `/etc/monitorix/monitorix.conf`
abgleichen, falls sich die Standardreihenfolge geändert hat.

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
Historie beginnt neu (Konvention anderer Monitorix-Module). Temperatur-DS (`t_*`,
`gm_t_*`) werden mit Minimum `U` angelegt, damit tatsächlich negative Werte erhalten
bleiben und nicht stillschweigend verworfen werden; alle übrigen DS nutzen Minimum
`0`. (Vor v1.3 erzeugte RRDs lassen sich ohne Datenverlust migrieren:
`rrdtool tune amdgpu_top.rrd --minimum <ds>:U` je Temperatur-DS.)

## Bewusst nicht abgebildet

- Statische Info-Felder (ASIC, VBIOS, CU-Anzahl …) → nur im Textmodus-Info-Block
- `PCI Power State`, `Power Profile` (Strings, keine Messwerte)
- `current_*`- und `average_core_power`-Arrays von `gpu_metrics`
  (Einheit/Aggregation undocumented; bei `cpu_favg/cpu_fmax` und `gm_t_core` wurde die
  Aggregation bewusst definiert, hier nicht)
- `gpu_metrics` VR-Temperaturen (`temperature_vrgfx` / `temperature_vrmem` /
  `temperature_vrsoc`) und Mittelwerte für Spannungen/Ströme (`average_*_voltage`,
  `average_*_current`) — von diesem Treiber/APU nicht geliefert (immer `null`),
  Dokumentationslage zu Einheiten dünn; bei Bedarf in `@DSPEC` ergänzen
- `gpu_metrics` `average_dclk1_frequency` / `average_vclk1_frequency` /
  `average_temperature_core` / `average_temperature_l3` (sekundäre Speicherkanäle
  bzw. Aggregat-Felder; auf dieser APU `null`)
- `gpu_metrics` `pcie_link_speed` / `pcie_link_width` (diskrete Linkzustände, keine
  Lastkurve) und `system_clock_counter` (roher monotoner Zähler)
- `Sensors` `"Fan Max"` (statischer Grenzwert) und `"Throttle Status"`
  (undurchsichtige Bitmaske)
- `xdna_fdinfo` (NPU-Auslastung; eigenes späteres Feature)
- Pro-PID-fdinfo-Details (dynamische PID-Liste → nur aggregierte `Total fdinfo`-Werte
  plus `proc_count`)

Einige erfasste DS erscheinen bewusst in keinem Panel (`fd_vram`, `fd_gtt`,
`pcie_lsp`, `cpu_favg/cpu_fmax`, `gm_t_l3`, `gm_p_cpu/gfx/soc`) — sie stehen für
eigene Graphen zur Verfügung.

## Hinweis zur DS-Benennung

RRD erlaubt max. 19 Zeichen je DS-Namen; die Suffixe sind entsprechend verkürzt und
mit den GRBM2-JSON-Keys (Achtung: teils **Doppel-Leerzeichen** im Original) exakt
abgestimmt. Neue DS daher immer gegen `docs/plan.md` §2.2 und die `@DSPEC`-Liste in
`amdgpu_top.pm` prüfen.

## Tests

```sh
./parse_test.pl    # Parser des Moduls selbst: 3 JSON-Samples + Live-Ausgabe
./t_robust.pl      # Robustheit: kaputtes/hängendes Tool, Sonderfälle, Schema-Rotation
./t_update.pl      # Update gegen RRD mit Exaktwertprüfung (~3 min)
./t_cgi.pl         # CGI-Funktion: Graph-/Textmodus, day/week
```

Ergebnisse protokolliert in `docs/testlog.md`. Alle Harnesses laden `amdgpu_top.pm`
aus dem Repo (niemals die installierte Kopie), testen also immer den Quellcode dieses
Baums.

## Fehlerbehebung

- `ERROR ... timed out after 30 seconds (GPU or driver unresponsive?)` im
  Monitorix-Log: `amdgpu_top` hing in einem DRM-Ioctl (z. B. während GPU-Reset). Das
  Modul hat abgeschossen und `U`-Werte geschrieben; `cmd_timeout` nur erhöhen, wenn
  das System legitimerweise langsam antwortet.
- `Can't exec "amdgpu_top"` auf Daemon-stderr (sichtbar in `journalctl -u
  monitorix`): Binary nicht im `PATH` des Daemons — absoluten Pfad in `cmd` setzen.
  Child-stderr wird ungefiltert ins Journal durchgereicht.
- Lücken in Panels: manche Sensorfelder liefern je nach Kernel intermittierend
  `null` (z. B. `temperature_tctl` auf gfx1151) — mit `use_nan_for_missing_data = y`
  korrekt als Lücke sichtbar.

## Dateistruktur

```
amdgpu_top.pm                  # das Monitorix-Modul (init/update/cgi, autark)
config/99-amdgpu_top.conf      # conf.d-Drop-in (installieren!)
t_update.pl t_cgi.pl t_robust.pl parse_test.pl   # Test-Harnesses
samples/                       # JSON-Samples (oneshot, nopc, dump)
docs/plan.md docs/environment.md docs/testlog.md # Auswertung/Plan/Protokoll
```
