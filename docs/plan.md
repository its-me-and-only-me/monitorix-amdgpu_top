# Plan: Monitorix-Perl-Modul `amdgpu_top`

Ziel: Ein eigenes Monitorix-Modul, das **alle zeitlichen Daten aus dem JSON-Output von `amdgpu_top`** erfasst (RRD) und als Diagramme + Textanszeige darstellt.

Projektverzeichnis: eigenes git-Repo `monitorix-amdgpu_top/` (atomare Commits pro Schritt).

Installationsziele:
- Modul: `/usr/lib/monitorix/amdgpu_top.pm`
- Konfiguration: `/etc/monitorix/conf.d/99-amdgpu_top.conf` (Drop-in, Hauptconfig bleibt unverändert)

---

## 1. Analyse-Ergebnisse (am Live-System verifiziert, 2026-11-09)

### 1.1 Umgebung
| Komponente | Stand |
|---|---|
| OS | Fedora 44 (Container-Image), SELinux **disabled** |
| Perl | 5.42.3; `JSON::PP` 4.16 (core) ✓, `JSON::XS` ✗ (fakultativ), `RRDs` ✓ |
| amdgpu_top | v0.10.5, `/usr/bin/amdgpu_top` |
| Monitorix | 3.16.0, RPM; Service aktuell **inactive** |
| GPU | 1× „Radeon 8060S Graphics“ (Strix Halo, gfx1151 **APU**) |
| httpd_builtin | enabled, Port **8080**, user/group `nobody` |
| Pfade | `base_lib=/var/lib/monitorix/`, `base_dir=/var/lib/monitorix/www/`, `include_dir=/etc/monitorix/conf.d` |

### 1.2 Datenquellen von amdgpu_top v0.10.5
1. **`amdgpu_top -J -n 1` (One-Shot, gewählte Quelle):**
   - `-n <u32>` = maximale Iterationsanzahl des JSON-Modus (Default 0 = Endlosschleife); mit **`-n 1`** terminiert das Tool sauber mit Exit-Code 0 nach **~1,1 s** und gibt genau **ein vollständiges JSON-Dokument als eine Zeile** aus (~7 KB).
   - Optional verkürzt `-s <ms>` (Refresh-Periode) die Laufzeit: `-n 1 -s 500` → ~0,6 s, Ausgabemenge identisch vollständig (verifiziert).
   - Enthält **ALLE** Daten inkl. GRBM/GRBM2-Performance-Counter und fdinfo. Kein `timeout`-Wrapper, keine SIGPIPE-Panics, keine halben Zeilen.
2. `amdgpu_top -J --dump`: terminiert sofort (43 ms), Array mit Info+Sensors+VRAM+gpu_activity+gpu_metrics — **ohne GRBM/GRBM2/fdinfo**. Nur für den Info-Block der Textansicherung genutzt (best-effort).
3. `-J --process`: ignoriert `-J` (nur Text) → **nicht verwendet**.
4. `--no-pc`: GRBM und GRBM2 sind dann `null` → Modul muss fehlende Werte tolerieren (NaN).
5. (`-J` allein ohne `-n` = Endlos-Streaming, 1 Dokument/Zeile/Sekunde — bewusst **nicht** verwendet.)

### 1.3 JSON-Schema von `amdgpu_top -J -n 1` (Dokument)
```
{
  "ROCm version": null,
  "amdgpu_top_version": {major, minor, patch},
  "devices": [ <Device>, ... ]
}
```
`<Device>`:
- `Info` (statisch): ASIC Name, DeviceName, GPU Family/Type, GPU Clock {max,min}, Memory Clock {max,min}, GTT Size, VRAM Size/Type/Bit width, Total Compute Unit, Shader Engine, RenderBackend, VBIOS {date,name,pn,ver_str}, Video Caps, PCI, ResizableBAR, drm_version, gfx_target_version …
- `Sensors`: `{unit, value}`-Paare oder Arrays oder null:
  - Temperaturen: `Edge Temperature`, `Junction Temperature`, `Memory Temperature`, `CPU Tctl` (°C); je `Edge/Junction/Memory Critical|Emergency Temperature`
  - Leistung: `Average Power`, `Input Power`, `GFX Power` (W)
  - Takte: `GFX_SCLK`, `GFX_MCLK` (MHz); `CPU Core freq` = Array 16× {core_id, thread_id, cur_freq, min_freq, max_freq}
  - Spannung: `VDDGFX`, `VDDNB` (mV)
  - `Fan`, `Fan Max` (Prozent; null bei APU), `PCIe Link Speed`, `PCI Power State` (String, z. B. „D0“), `Power Profile` (null/String)
- `VRAM`: `Total VRAM`, `Total VRAM Usage`, `Total GTT`, `Total GTT Usage` (je {unit:"MiB", value})
- `gpu_activity`: `GFX`, `MediaEngine`, `Memory` (je {unit:"%", value}; Memory kann null sein)
- `GRBM` (8 × {unit:"%", value}): Graphics Pipe, Texture Pipe, Primitive Assembly, Shader Export, Shader Processor Interpolator, Color Block, Depth Block, Geometry Engine
- `GRBM2` (9 × {unit:"%", value}): Command Processor - Graphics, Command Processor -  Compute (⚠ zwei Leerzeichen!), Command Processor -  Fetcher, Efficiency Arbiter, Ring List Controller, SDMA, Texture Cache per Pipe, Render Backend Memory Interface, Unified Translation Cache Level-2
- `gpu_metrics` (flaches Objekt; kann null sein): Temperaturen ×100 (z. B. `temperature_gfx`: 3275 → 32,75 °C): `temperature_gfx|soc|edge|hotspot|mem|l3|vrgfx|vrmem|vrsoc`, `temperature_core` = Array 16×; Durchschnittstakte (MHz): `average_gfxclk|fclk|uclk|socclk|vclk|vclk1|dclk|dclk1_frequency`; Leistungen (mW!): `average_socket_power` (55957 ≈ 56 W), `average_cpu_power`, `average_gfx_power`, `average_soc_power`; Spannungen: `voltage_gfx|soc|mem`; Ströme; `fan_pwm`; `pcie_link_speed/width`; `Throttle Status`; `current_*`-Arrays, `average_core_power`-Array (Einheit unklar → nicht gemappt)
- `fdinfo`: `{ "<pid>": {name, usage: {CPU %, Compute %, DMA %, Decode %, Encode %, GFX %, GTT MiB, Media %, VCN_JPEG %, VCN_Unified %, VPE %, VRAM MiB}} }` (dynamische Prozessliste)
- `Total fdinfo`: dieselben 12 usage-Felder als Summen
- `xdna_fdinfo`: NPU-Info (hier nicht vorhanden/null) → nur Textansicht, keine RRD

### 1.4 Monitorix-3.16-Architektur (verifiziert aus /usr/bin/monitorix, HTTPServer.pm, monitorix.cgi, amdenergy.pm, nvidiagpu.pm)
- Moduldatei `/usr/lib/monitorix/<name>.pm`, `package <name>;`, Export `qw(<name>_init <name>_update <name>_cgi)`. **Keine Registrierung im Hauptskript nötig** — `/usr/bin/monitorix` macht dynamisch `use $g qw(${g}_init ${g}_update)` für jeden in `graph_name` + `graph_enable=y` genannten Graphen; `monitorix.cgi` analog `use $gn qw(${gn}_cgi)`.
- Signaturen: `<name>_init($package, \%config, $debug)`, `<name>_update($package, \%config, $debug)` (läuft 1×/Minute, Daemon = root → fdinfo-Lesezugriff), `<name>_cgi($package, \%config, \%cgi)` (läuft als **nobody** → im CGI **keine** externen GPU-Kommandos erzwingen; nur best-effort mit eval).
- `_init` erstellt das RRD (`$config->{base_lib} . $package . ".rrd"`) und pusht `$package` auf `@{$config->{func_update}}`.
- conf.d-Merge (`/etc/monitorix/conf.d/*.conf`, sowohl Daemon als auch CGI):
  - `additional_graph_name = amdgpu_top` → wird an `graph_name` **angehängt**
  - `<graph_enable> amdgpu_top = y </graph_enable>` → Hash-Merge
  - `<graph_title>`: `amdgpu_top = …` (Modultitel, aus `$config->{graph_title}->{$package}`); Plot-Titel aus `<graphs>`: `_amdgpu_top1 … _amdgpu_topN` (Zugriffspfad `$config->{graphs}->{'_amdgpu_top'.$n}` — flach, gruppenunabhängig). **Korrektur Step 5:** die Sektion heißt real `<graph_title>`, nicht `<descriptions>`.
- Bildnamen-Konvention (CGI): `"$u$package$k$n[.z].$tf->{when}.$imgfmt"` → `amdgpu_top00.day.png`, Zoom `amdgpu_top00z.day.png` in `$config->{base_dir}/$config->{imgs_dir}`.
- RRD-Konventionen: `DS:<name>:GAUGE:120:0:U`; **DS-Namenslimit 19 Zeichen**; Standard-RRA-Set wie amdenergy.pm (AVERAGE/MIN/MAX/LAST je 1:1440, 30:336, 60:744 + `max_historic_years`-RRAs); Größenänderung → `.bak` + Neubau mit Log-Hinweis.
- Nützliche Helpers aus `Monitorix.pm`: `logger()`, `trim()`, `setup_riglim()`, `celsius_to()`; CGI-Setup: `$cgi->{tf}`, `$cgi->{colors}`, `$cgi->{graph}`, `$cgi->{silent}`, `$config->{global_zoom}`, `$config->{image_format}`, `main::graph_header/graph_footer`, `main::graph_descr`.
- Referenzmodul für Multi-Plot-Gruppen: `/usr/lib/monitorix/nvidiagpu.pm` (Plots pro Gruppe, `show_current_values`, `use_nan_for_missing_data`, `<map>`, `rigid`/`limit`).
- Debug/Test: `monitorix -n -d amdgpu_top` (Foreground), Log-Ausgaben; httpd_builtin :8080 für `monitorix.cgi?g=amdgpu_top&t=day`.
- Der eingebaute Modulname `amdgpu` existiert bereits (sysfs-basiert) → unser Modul heißt **`amdgpu_top`**, keine Kollision.

---

## 2. Design

### 2.1 Konfiguration (`/etc/monitorix/conf.d/99-amdgpu_top.conf`)
```
additional_graph_name = amdgpu_top

<graph_enable>
	amdgpu_top	= y
</graph_enable>

<graph_title>
	amdgpu_top		= AMD GPU statistics (amdgpu_top JSON)
</graph_title>

<graphs>
	_amdgpu_top1	= GPU usage
	_amdgpu_top2	= GRBM engines
	_amdgpu_top3	= GRBM2 engines
	_amdgpu_top4	= Temperatures
	_amdgpu_top5	= Clocks
	_amdgpu_top6	= Power
	_amdgpu_top7	= Memory usage
	_amdgpu_top8	= Voltage
	_amdgpu_top9	= Fan speed
	_amdgpu_top10	= Media engine usage
</graphs>

<amdgpu_top>
	<list>
		0 = 0
	</list>
	cmd		= amdgpu_top -J -n 1
	no_pc		= n
	use_nan_for_missing_data	= y
	show_current_values		= y
	show_info				= y
	<map>
		0 = Radeon 8060S
	</map>
</amdgpu_top>
```
- `<list>`: Gruppen `k = <device-index>[, <device-index>…]`; Index = Position im `devices[]`-Array. Max. 8 Geräte/Gruppe (wie amdenergy).
- `cmd` überschreibbar (Default `amdgpu_top -J -n 1`; `-n 1` = One-Shot, terminiert von selbst); `no_pc = y` ergänzt `--no-pc` (schont APU-Power; GRBM/GRBM2 → NaN). Kein eigenes `timeout`-Optionsfeld nötig.
- `show_info` (CGI-Textmodus): versucht `amdgpu_top -J --dump` (terminiert ohnehin sofort, ~43 ms) für den statischen Info-Block; scheitert still (nobody/`/dev/dri`-Rechte) → Hinweis „not available“.

### 2.2 RRD-Datenquelle-Schema (79 DS pro Geräteslot, Präfix `e<k>d<n>_`, ≤ 19 Zeichen)

| Bereich | DS-Suffix | JSON-Pfad (relativ zu devices[i]) | Umrechnung |
|---|---|---|---|
| Activity | act_gfx, act_media, act_mem | gpu_activity.{GFX,MediaEngine,Memory} | – |
| GRBM (8) | g_pipe, t_pipe, prim_asm, sh_export, sh_interp, color_blk, depth_blk, geom_eng | GRBM.<name> | – |
| GRBM2 (9) | cp_gfx, cp_comp, cp_fetch, eff_arb, ring_ctrl, sdma, tex_cache, rb_memif, utc_l2 | GRBM2.<name> (exakte Keys inkl. Doppel-Leerzeichen!) | – |
| Temp. (10) | t_edge, t_junc, t_mem, t_tctl, t_edg_crit, t_jnc_crit, t_mem_crit, t_edg_emer, t_jnc_emer, t_mem_emer | Sensors.<name> | – |
| Power (3) | p_avg, p_input, p_gfx | Sensors.{Average,Input,GFX} Power | – |
| Clocks (2) | sclk, mclk | Sensors.{GFX_SCLK,GFX_MCLK} | – |
| Volt (2) | vddgfx, vddnb | Sensors.{VDDGFX,VDDNB} | – |
| Fan (1) | fan | Sensors.Fan | – |
| PCIe (1) | pcie_lsp | Sensors."PCIe Link Speed" | – |
| CPU-Freq (2) | cpu_favg, cpu_fmax | Sensors."CPU Core freq"[] cur_freq | Mittel / Maximum über Kerne |
| VRAM (4) | vram_tot, vram_use, gtt_tot, gtt_use | VRAM.{Total VRAM,Total VRAM Usage,Total GTT,Total GTT Usage} | – |
| gpu_metrics (21) | gm_t_gfx, gm_t_soc, gm_t_edge, gm_t_hot, gm_t_mem, gm_t_l3, gm_t_core | gpu_metrics.temperature_*  (core = Array-Mittel, nur >0) | ÷100 → °C |
| | gm_agfxclk, gm_afclk, gm_auclk, gm_asocclk, gm_avclk, gm_adclk | gpu_metrics.average_*_frequency | – |
| | gm_p_sock, gm_p_cpu, gm_p_gfx, gm_p_soc | gpu_metrics.average_*_power | ÷1000 → W |
| | gm_v_gfx, gm_v_soc, gm_v_mem | gpu_metrics.voltage_gfx/soc/mem | – |
| | gm_fan_pwm | gpu_metrics.fan_pwm | – |
| fdinfo (13) | fd_cpu, fd_comp, fd_dma, fd_dec, fd_enc, fd_gfx, fd_media, fd_jpeg, fd_vcn, fd_vpe, fd_vram, fd_gtt | Total fdinfo.* | – |
| | proc_count | Anzahl fdinfo-Hash-Keys | – |

Nicht gemappt (bewusst, in README dokumentiert): statische Info-Felder (nur Text-Info-Block), `PCI Power State`/`Power Profile` (Strings), `current_*`- und `average_core_power`-Arrays (Einheit/Aggregation unklar), `xdna_fdinfo`, pro-PID-fdinfo (dynamische Liste → nur `proc_count` + Totalwerte), Alerts (nicht Teil von v1).

Fehlende/null-Werte: `use_nan_for_missing_data=y` → `U`(NaN), sonst `0` (Konvention amdenergy/nvidiagpu).

### 2.3 Diagramm-Panels pro Gruppe (10 Plots, `main`-Größe für 1–7, `small` für 8–10 analog nvidiagpu) — ** Layout siehe „Änderungen nach v1.0“ **
1. **GPU usage (%)**: act_gfx, act_media, act_mem, fd_gfx, fd_cpu, fd_comp, fd_dma, fd_media (LINE)
2. **GRBM engines (%)**: 8 LINEs
3. **GRBM2 engines (%)**: 9 LINEs
4. **Temperatures (°C)**: t_edge, t_junc, t_mem, t_tctl, gm_t_gfx, gm_t_soc, gm_t_core, gm_t_hot
5. **Clocks (MHz)**: sclk, mclk, gm_agfxclk, gm_afclk, gm_auclk, gm_asocclk
6. **Power (W)**: p_avg, p_input, p_gfx, gm_p_sock
7. **Memory usage (MiB)**: vram_tot (AREA Hintergrund), vram_use, gtt_tot (AREA hell), gtt_use
8. **Voltage (mV)**: vddgfx, vddnb, gm_v_gfx, gm_v_soc, gm_v_mem
9. **Fan speed (%)**: fan, gm_fan_pwm
10. **Media engine usage (%)**: fd_dec, fd_enc, fd_media, fd_jpeg, fd_vcn, fd_vpe

Farbpaletten wie amdenergy/nvidiagpu (zwei zyklische @LC); `show_current_values` → GLEG-Legende mit aktuellen Werten; `rigid`/`limit` pro Plot; Zoom-PNGs bei `enable_zoom=y`; Standard-`@extra` aus `rrdtool_extra_options`.

### 2.4 Datenerfassung (nur Daemon!)
```perl
open(my $fh, "-|:encoding(UTF-8)", split(' ', $cmd), (@no_pc ? ("--no-pc") : ()))  # Default: amdgpu_top -J -n 1
local $/; my $json = <$fh>; close($fh);   # Kind terminiert selbst (Exit 0), kein timeout-Wrapper nötig
my $data = eval { decode_json($json) };   # ein vollständiges Dokument
```
Ein Aufruf pro Update-Minute (~0,6–1,1 s); Parse-Fehler/leere Ausgabe → NaN schreiben + `logger()`-Warnung (max. 1×/Update, nicht minütlich zuspammen).

### 2.5 Textmodus des CGIs
Standard-RRD-Fetch-Tabelle (wie amdenergy) **ohne** externen Aufruf, gruppiert nach sinnvollen Zeilen (usage %, temps, clocks, power, memory). Zusätzlich bei `show_info=y` und **nicht** Silent-Multihost: Info-Block (Gerätename, ASIC, VRAM-Typ/-Größe, CU-Anzahl, VBIOS, amdgpu_top-Version) via `amdgpu_top -J --dump` (sofort terminierend) mit graceful fallback.

---

## 3. Arbeitspakete (jeweils eigenständig nach `/compact` ausführbar)

> Jeder Schritt: Änderungen committen (Konvention: `step N: <beschreibung>`), `perl -c` obligatorisch, DoD abhaken.
> Vor jedem Schritt: `plan.md` (diese Datei) + Dateien im Projektverzeichnis lesen. Nicht auf Inhalte alter Sessions/Verzeichnisse (`monitorix.gemma-4/` etc.) zurückgreifen.

### Schritt 0 — Projektgerüst und Beispiel-Daten sichern
- `mkdir monitorix-amdgpu_top && cd` rein, `git init`, `.gitignore` (imgs, *.rrd, tmp).
- `docs/environment.md`: Analyse-Konfiguration aus Abschnitt 1 festschreiben (Befehle + Ausgaben): `amdgpu_top -J -n 1` → `samples/oneshot.json`, `amdgpu_top -J --dump` → `samples/dump.json`, `amdgpu_top -J -n 1 --no-pc` → `samples/nopc.json`.
- DoD: Repo initialisiert, 3 valide JSON-Samples mit `jq` bestätigt.

### Schritt 1 — Parser/Kernlogik als Standalone: `lib/AmdgpuTopParser.pm`
- Eigene Package (später 1:1 ins Modul übertragbar): `collect_json(\%opts)` (One-Shot-Pipe `amdgpu_top -J -n 1`, Ausgabe komplett einlesen, `decode_json`; `--file <pfad>` für Offline-Tests) und `extract_values($device_href)` → Flat-Hash exakt der 79 DS-Suffixes aus 2.2 (mit allen null-/fehlend-/Array-Toleranzen, Umrechnungen °C/100, mW/1000, CPU-Frequenz-Mittel/Max, proc_count).
- `parse_test.pl`: CLI (`--file samples/*.json` oder live), tabellarischer Ausdruck aller Werte,Exit 0 bei Erfolg.
- DoD: `perl -c` sauber; Test gegen alle 3 Samples (nopc: GRBM-Felder = NaN/undef); Live-Test liefert plausible Werte (VRAM>0, Takt ~1000–2900, Temps 20–80).

### Schritt 2 — Moduldatei anlegen: `_init` mit RRD-Erzeugung
- `amdgpu_top.pm`: Header wie amdenergy (GPL-Kommentar, `package amdgpu_top;`, `@EXPORT`), Parser-Code **inline** ins Modul übernehmen (Monitorix-Module sind self-contained; Standalone-Package bleibt als Testvehicle erhalten), `amdgpu_top_init`: OS-Guard, Config-Defaults (cmd/no_pc/use_nan), Kommandoverfügbarkeit (ein Testlauf `amdgpu_top -J -n 1` mit Parse-Prüfung schlägt fehl → Log + return), RRD-Größenvergleich (Gruppen×Geräte×79 DS) mit `.bak`-Rotation, `RRDs::create` mit vollem DS-Schema + Standard-RRA-Set, `push(@{$config->{func_update}}, $package)`.
- DoD: `perl -I/usr/lib/monitorix -c amdgpu_top.pm` OK.

### Schritt 3 — `_update` + Offline-Funktionsprüfung
- `amdgpu_top_update`: collect → je Gruppe/Slot `N:<v>:...`-String (Reihenfolge = DS-Erzeugungsreihenfolge!), NaN/0 je Config, `RRDs::update`, Debug-Log, Fehler-Log via `RRDs::error`.
- Test-Harness `t_update.pl`: baut `%config` selbst (base_lib=`./test/`, list={0=>"0"}, use_nan=y), ruft `amdgpu_top_init`/`_update` mit Sample-Daten (Parser-Modus `--file`) auf; prüft `rrdtool info` (DS-Anzahl=79) und `rrdtool last`/`fetch`.
- DoD: RRD entsteht, `rrdtool fetch ... AVERAGE -r 60 -s -300` zeigt reale Werte an den erwarteten DS-Positionen (Stichproben: vram_use, sclk, t_tctl, gm_p_sock ≈ 40–80).

### Schritt 4 — Konfig-Drop-in und Live-Betrieb des Daemons ✅ (2026-11-09)
- `/etc/monitorix/conf.d/99-amdgpu_top.conf` nach 2.1 angelegt (zuerst im Projektversioniert, dann kopiert).
- Test: `timeout 130 monitorix -c /etc/monitorix/monitorix.conf -n -d all` → Log zeigt `amdgpu_top_init: Ok`, minütliche Updates, RRD `/var/lib/monitorix/amdgpu_top.rrd` aktuell.
- **Erkenntnis:** Die Debug-Key-Validierung läuft VOR dem conf.d-Merge → `-d amdgpu_top` stirbt mit „Invalid debug key“; `-d all` benutzen.
- DoD: RRD minütlich aktualisiert; keine WARNINGS/Fehler im Log; `rrdtool fetch` live plausibel. ✓

### Schritt 5 — `_cgi` Graph-Modus (10 Panels) ✅ (2026-11-09)
- Umsetzung nach 2.3 + amdenergy/nvidiagpu-Muster: IMG/IMGz-Arrays, `setup_riglim`, @LC-Farben (11), LINE2 (main) / LINE1 (small), Panel 7 mit AREA-Hintergründen, `--vertical-label` je Panel, `graphv`, Zoom, Panels 1–7 `main` mit Current/Average/Min/Max-Legende, Panels 8–10 `small` + version12_small + Kurzwert-Legende bei `show_current_values`.
- Höhenanpassung: +13 px (main) bzw. +10 px (small) pro Legendenzeile über 1 hinaus, damit 8–9-zeilige Legenden passen.
- Temperaturpanel: CDEF-Umrechnung auf Fahrenheit bei `temperature_scale = f`.
- Lücken-Markierung (`show_gaps`) nutzt allvalues mit `UN,0,1,IF` → Panel wird nur eingefärbt, wenn ALLE seine DS NaN sind (APU-sicher; Simple-Summe wie nvidiagpu würde bei einem fest-null-Sensor das ganze Panel grau malen).
- **Erkenntnisse (wichtig für Doku):**
  1. Modultitel kommen aus Sektion `<graph_title>` (NICHT `<descriptions>` wie im Plan-Entwurf); Plot-Titel aus `<graphs>` (`_amdgpu_topN`). Beides wird per conf.d-Hash-Merge ergänzt.
  2. CGI-URL-Parameter sind `mode=localhost&graph=amdgpu_top&when=day&color=white` (NICHT `g=`/`t=`); `mode` fehlt → gar kein Modul rendert.
  3. PNG-Namen nutzen `tf->{when}` = `"1day"` → Dateien heißen `amdgpu_top00.1day.png` usw.
  4. `enable_parallelizing = y` (Default) forked Module; Kind-Die/Stderr verschwinden → direkter Funktionsaufruf via Harness `t_cgi.pl` als primärer Testweg.
- Test: `./t_cgi.pl` (Graph-Tages-, Text-Tages-, Text-Wochen-Szenario) ALL CHECKS PASSED; E2E `curl 'http://localhost:8080/monitorix.cgi?mode=localhost&graph=amdgpu_top&when=day&color=white'` → 20 IMG-Referenzen (10 + 10 Zoom), keine ERRORs, PNGs in `/var/lib/monitorix/www/imgs/` visuell geprüft (Temperatures, Memory usage, Media engine usage). ✓

### Schritt 6 — Visuelle Abnahme + Textmodus ✅ (2026-11-09)
- Alle 10 Panels visuell geprüft (Read-Tool auf `/var/lib/monitorix/www/imgs/amdgpu_top0{0..9}.1day.png`): Kurven plausibel (SCLK bis 2802 MHz, Power bis 108 W, GRBM/GRBM2-Aktivität korrekt), 4-Werte-Legenden (Current/Average/Min/Max) bei Panels 1–7 lesbar, kleine Panels 8–10 mit Kurzwert-Legende, fehlende APU-Sensoren (Fan, gm-Voltages, Memory-Temp) sauber als -nan ohne Artefakte.
- Voltage-Panel zeigt VDDGFX/VDDNB = 0.0: **korrekt** — `amdgpu_top` liefert auf gfx1151 real `{"unit":"mV","value":0}` (kein Parse-/NaN-Fehler).
- Textmodus (Tabelle + Info-Block via `--dump`) bereits in Schritt 5 verifiziert; HTML-Zweispaltenlayout im E2E-HTML bestätigt (`<td>` Panels 1–5, `<td class='td-valign-top'>` Panels 6–10, Titel colspan=2).
- DoD erfüllt: E2E `curl 'http://localhost:8080/monitorix.cgi?mode=localhost&graph=amdgpu_top&when=day&color=white'` → 20 PNGs, 0 ERRORs, keine RRDtool-Fehler im HTML. ✓

### Schritt 7 — Robustheit & Sonderfälle ✅ (2026-11-09)
- Tests in `t_robust.pl` (Assertions auf den bei `debug=1` geloggten Update-String, da rrdtool Buckets lazy konsolidiert): (a/a2) `no_pc=y` Datei+live → GRBM/GRBM2 `U` ohne Crash; (b) kaputte Ausgabe bei init → ERROR-Log, `_init` bricht bewusst vor RRD-Anlage ab; (b1) Tool weg NACH init → alle DS `U`, RRD bleibt, Daemon läuft weiter; (b2) Binary fehlt; (b3) `file` fehlt; (c) Index außerhalb `devices[]` → Slot `U` + WARNING; (c2) nicht-numerischer Index → ERROR + `U`; (d) `use_nan_for_missing_data=n` → 0er statt `U`; (e) „0, 0“ → 158 DS, beide Blöcke identisch; (f) fremdes RRD → `.bak`-Rotation + 79 DS.
- DoD: alle Fälle protokolliert in `docs/testlog.md`. ✓ ALL CHECKS PASSED

### Schritt 8 — Dokumentation & Abschluss ✅ (2026-11-09)
- `README.md` angelegt: Installation (Modul → `/usr/lib/monitorix/`, Drop-in → `/etc/monitorix/conf.d/`, Restart), alle Config-Optionen, 79er-DS-Schema-Tabelle, bewusst Nicht-Abgebildetes (Info-Felder, Strings, Core-Power-Arrays, xdna_fdinfo, Pro-PID-fdinfo), Hinweis „DS-Änderung ⇒ RRD-Neubau mit .bak-Rettung“, Testkommandos.
- Finaler End-to-End: `systemctl enable --now monitorix` → enabled + active; zwei Update-Zyklen verifiziert (lastupdate +121 s, frische Werte im RRD); WebUI belegt (20 Panel-PNGs + HTML, docs/testlog.md). Installierte Dateien = Repo-Stand (diff leer).
- Beobachtung: gfx1151 liefert Sensorwerte (z. B. `temperature_tctl`) zeitweise `null` — Modul schreibt korrekt NaN (Lücke im Graph), Tool-/Hardware-verhalten, kein Modulbug.
- Repo-Cleanup (Testartefakte gitigignored), Tag `v1.0`. ✓

---

## 4. Risiken / Einschränkungen
- **DS-Namen ≤ 19 Zeichen** → verkürzte Suffixe (Tabelle 2.2); bei Erweiterungen unbedingt prüfen.
- **Schemaänderungen zerstören Historie** → Modul macht `.bak` + Logwarnung (Konvention anderer Module).
- GRBM2-Keys enthalten teils **Doppel-Leerzeichen** → exakt kopieren, sonst immer NaN.
- CGI läuft als `nobody`: externer `--dump`-Info-Block ist best-effort und **muss** scheitern dürfen.
- One-Shot-Aufruf (`-n 1`) braucht ~0,6–1,1 s: Update-Dauer pro Minute unkritisch; bei >1 Gruppen bleibt es **ein** `amdgpu_top`-Aufruf (alle Geräte im einen Dokument).
- Monitorix 3.16 `graph_title`/`graphs`-Hashes: `_amdgpu_top#`-Namen müssen exakt zu Panelanzahl passen (Indexseite).
- Werte-Einhängung an `--dump` in Schritt 1 offline nur so gut wie die Samples; Live-Werte können sich ändern (deshalb jeder Schritt mit Live-Gegenprobe).

---

## 5. Änderungen nach v1.0 (Nutzerfeedback, 2026-11-09)

1. **Layout:** links drei `main`-Panels — GPU usage, Power, Memory usage — rechts
   sieben `small`-Panels (GRBM, GRBM2, Temperatures, Clocks, Voltage, Fan speed,
   Media engine usage). Umsetzung: Reihenfolge in `@PANELS` geändert,
   `$main_size_plots = 3`, `$main_column_plots = 3`; `<graphs>`-Namen im Drop-in auf
   die neue Positionsreihenfolge gebracht (PNG-Indexierung folgt der Renderposition).
2. **`amdgpu`-Ersetzung:** Drop-in setzt `graph_name` komplett (Kopie der
   Hauptconfig-Liste, `amdgpu` → `amdgpu_top`) statt `additional_graph_name` und
   deaktiviert `amdgpu` über `<graph_enable>`. Das Modul erscheint exakt an der alten
   `amdgpu`-Position im Menü; `amdgpu.rrd` wird nicht mehr aktualisiert.
   `additional_graph_name` und `graph_name`-Override dürfen **nicht beide** gesetzt
   sein (Hash-Reihenfolge der conf.d-Merge-Session ist nicht deterministisch).
   Hinweis für Monitorix-Upgrades: `graph_name`-Zeile gegen die Hauptconfig prüfen.
3. **Render-Pass für AREA-Hintergründe:** Panel-Schleife zeichnet jetzt in zwei Pässen
   (erst alle `AREA`-Hintergründe, dann alle Linien), damit im Memory-Panel das später
   gezeichnete `gtt_tot`-AREA nicht mehr die VRAM-Linien zudeckt.
4. **`panels`-Option (CGI-only):** permanent leere Panels auf dieser Hardware
   (8 Voltage: `vddgfx`/`vddnb` konstant 0, `gm_v_*` `null`; 9 Fan speed: `fan`/
   `gm_fan_pwm` `null`; 10 Media engine: `fd_dec`/`fd_enc` `null`,
   `fd_media`/`fd_jpeg`/`fd_vcn`/`fd_vpe` konstant 0 — je 8 h Live-Daten) sind im
   Drop-in über `panels = 1, 2, 3, 4, 5, 6, 7` ausgeblendet; die Titel
   `_amdgpu_top8/9/10` sind dort kommentiert. Alle 79 DS werden unverändert
   weiter aufgezeichnet → Reaktivierung (Nummer zu `panels` + Titel entkommentieren)
   ist ohne Historienverlust möglich. Umsetzung im CGI: `@panel_list` (Default alle
   10, Warnung bei ungültigen Einträgen), Panel-Identität über ursprüngliche Nummer
   `$pn` (rigid/limit, Plot-Titel, `$e2`), PNG-/IMG-Index über Renderposition;
   Spaltensprung nach dem letzten sichtbaren `main`-Panel. `t_cgi.pl` leitet die
   erwartete Panel-/Bildzahl jetzt dynamisch aus der Config ab.

5. **Code-Review-Follow-ups (2026-11-10, externer Review → v1.3):** harter
   Timeout um alle `amdgpu_top`-Aufrufe (`cmd_timeout`, Default 30 s; kill + `U`
   statt Daemon-Hang; Robustheitsszenario g), Temperatur-DS mit Min `U`
   (Live-Migration per `rrdtool tune`), imagetag-IDs auf Gruppen-Konvention
   (`$e2 = $e + 1`, verankerter Match), Memory-Panel zeichnet GTT-Backdrop zuerst,
   CGI-Warnung via `@output` statt `logger()`, `<list>` toleriert `0,1` und
   einfache Quotes, Zoom-Bilder erhalten den Legenden-Zuschlag, Info-Block nutzt
   `<map>`, `parse_test.pl` testet jetzt das echte Modul (Duplikat
   `lib/AmdgpuTopParser.pm` entfernt; alle Harnesses laden den Repo-Stand —
   vorher luden sie durch `use lib`-Reihenfolge die installierte Kopie!), tote
   Imports entfernt, README-Defaults korrigiert + Doku vervollständigt.
