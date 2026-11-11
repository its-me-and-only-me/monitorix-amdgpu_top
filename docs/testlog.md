# Testprotokoll — Monitorix-Modul `amdgpu_top`

Stand: 2026-11-09 · Monitorix 3.16.0 · Perl 5.42.3 · RRDs 1.9 · amdgpu_top v0.10.5 ·
Hardware: 1× „Radeon 8060S Graphics“ (Strix Halo, gfx1151 APU) · Fedora 44 (Container)

Alle Test-skripte liegen im Repo-Wurzelverzeichnis und sind idempotent; sie schreiben nur
unter `test*/` bzw. `/tmp/opencode/` und verändern die Produktivinstallation nicht.

## Übersicht der Testwege

| Skript | Zweck | Ergebnis |
|---|---|---|
| `parse_test.pl` | Parser `lib/AmdgpuTopParser.pm`: 79 DS aus JSON (3 Samples + live + live `--no-pc`) | ✅ alle grün (Schritt 1) |
| `t_update.pl` | Init+Update gegen RRD mit geprüfter RRD-Zeitsemantik (Exaktwerte, Slot-Offsets, NaN-Policy, kaputtes Kommando) | ✅ ALL CHECKS PASSED (Schritt 3) |
| `t_cgi.pl` | CGI-Funktion im reproduzierten monitorix.cgi-Kontext: Graph (day), Text (day), Text (week) | ✅ ALL CHECKS PASSED (Schritt 5) |
| `t_robust.pl` | Robustheit/Sonderfälle (Schritt 7, Details unten) | ✅ ALL CHECKS PASSED |
| E2E per HTTP | `curl 'http://localhost:8080/monitorix.cgi?mode=localhost&graph=amdgpu_top&when=day&color=white'` | ✅ 20 IMG-Refs (10 + 10 Zoom), 0 ERRORs (Schritt 5/6) |
| Live-Daemon | `systemctl start monitorix`; `/var/lib/monitorix/amdgpu_top.rrd` wächst minütlich | ✅ (Schritt 4) |

## Schritt 7 — Einzelprüfungen (`./t_robust.pl`)

Jedes Szenario läuft in eigenem Verzeichnis mit frischem RRD; die Assertions parsen den
vom Modul bei `debug=1` geloggten RRD-Update-String (`N:v1:v2:…`, 79 Werte pro Slot).

### a) `--no-pc` JSON über `file` (samples/nopc.json)
- ✅ keine Exception; Update-String hat exakt 79 Werte; RRD hat 79 DS
- ✅ GRBM (`g_pipe`), GRBM2 (`cp_comp`, `utc_l2`) = `U` (im JSON `null`)
- ✅ Nicht-GRBM-Werte intakt: `act_gfx`=8, `t_edge`=40, `vram_use`=367

### a2) `--no-pc` live (`no_pc = y`, echtes `amdgpu_top -J -n 1 --no-pc`)
- ✅ keine Exception; `g_pipe` = `U`; `gm_p_sock` definiert (19.6 W)

### b) kaputte Kommando-Ausgabe bei init (`cmd = /usr/bin/printf bogus-not-json`)
- ✅ keine Exception; `ERROR: JSON parse error …` geloggt
- ✅ **Erkenntnis:** `_init` bricht vor RRD-Anlage ab (bewusstes Design, wie bei anderen
  Monitorix-Modulen — kein RRD bei unbrauchbarer Datenquelle). Ein bereits vorhandener
  RRD bleibt erhalten (siehe b1).

### b1) Tool fällt NACH erfolgreichem init weg (Simulation Deinstallation)
- ✅ keine Exception; `ERROR … unable to execute 'definitely_not_installed_xyz …'` geloggt
- ✅ Update schreibt 79× `U`; vorhandener RRD bleibt erhalten → Daemon läuft stabil weiter

### b2) Kommando-Binary existiert nicht (direkt im ersten Update)
- ✅ keine Exception; `unable to execute …: No such file or directory` geloggt; alle DS `U`
- Hinweis: Perl schreibt zusätzlich „Can't exec …“ nach STDERR (Standardverhalten von
  `open "-|"`), für den Daemon harmlos.

### b3) `file`-Option zeigt auf nicht existierende Datei
- ✅ keine Exception; `unable to open '…does_not_exist.json'` geloggt; alle DS `U`

### c) Geräteindex außerhalb `devices[]` (`list: 0 = 7`)
- ✅ keine Exception; `WARNING: device index 7 not found in amdgpu_top output (group 0).`
- ✅ Slot bleibt vollständig `U` (kein Überschreiben mit Müll)

### c2) nicht-numerischer Geräteindex (`list: 0 = abc`)
- ✅ keine Exception; `ERROR: invalid device index 'abc' in group 0.`; Slot bleibt `U`

### d) `use_nan_for_missing_data = n`
- ✅ keine Exception; **kein einziges `U`** im Update-String
- ✅ fehlende Werte werden zu 0: `g_pipe`=0, `t_junc`=0; vorhandene Werte korrekt: `t_edge`=40

### e) zwei Slots `0, 0` in einer Gruppe (DS-Offset-Test)
- ✅ 158 DS (2 × 79); Update-String mit 158 Werten
- ✅ alle 79 Wertepaare `e0d0_*` == `e0d1_*` byte-identisch → Slot-Offsets korrekt

### f) veraltetes/fremdes RRD-Schema am Zielpfad
- ✅ keine Exception; alte Datei nach `.bak` rotiert; neues RRD mit exakt 79 DS
- ✅ Rotation geloggt; erstes Update nach Rotation schreibt 53 definierte Werte

## Visuelle Abnahme (Schritt 6)

Alle 10 Panels (`/var/lib/monitorix/www/imgs/amdgpu_top0{0..9}.1day.png`) geprüft:
- Kurvenverläufe plausibel (GFX-Auslastung, GRBM/GRBM2-Engines korreliert,
  SCLK bis 2802 MHz, MCLK 1000 MHz, Power bis ~108 W)
- Legenden: Panels 1–7 Current/Average/Min/Max je DS; Panels 8–10 Kurzwert-Legende
- Fehlende APU-Sensoren (Fan, Memory-Temp, gm-Spannungen) sauber als `-nan`, keine Artefakte
- Voltage-Panel zeigt VDDGFX/VDDNB = 0.0: **korrekt so** — `amdgpu_top` liefert auf
  gfx1151 real `{"unit":"mV","value":0}`
- Zweispaltenlayout im gelieferten HTML bestätigt (Panels 1–5 links, 6–10 rechts)

## RRD-Lesesemantik (wichtiges Test-Nebenwissen)

- Ein GAUGE-Update mit Timestamp == `last_update` (Create und Update in derselben Sekunde)
  wird von rrdtool **still ignoriert** (nur `last_update` läuft).
- Ein geschlossenes Bucket wird **lazy** erst mit dem *nächsten* Update ins RRA
  konsolidiert und ist vorher per `fetch` nicht lesbar.
- Deshalb: Exaktwert-Tests in `t_update.pl` mit Minute-Boundary-Waits; die schnellen
  `t_robust.pl`-Assertions prüfen den geloggten Update-String statt des Fetch-Ergebnisses.

## Wiederholen der Tests

```sh
./parse_test.pl            # ~10 s
./t_robust.pl              # ~30 s
./t_update.pl              # ~3 min (wartet auf Minuten-Grenzen)
./t_cgi.pl                 # ~10 s  (auch: --text, --when 1week)
```

---

## Nachlauf 2026-11-10 — Review-Fixes (v1.3)

Verifikation der Review-Behobungen (Umgebung wie oben):

| Harness | Ergebnis |
|---|---|
| `./parse_test.pl --file samples/*.json` + Live | OK — testet jetzt `amdgpu_top.pm` selbst (53/36/25 von 79 Werten definiert wie zuvor) |
| `./t_robust.pl` | ALL CHECKS PASSED — 11 Szenarien inkl. neuem `g)` hängendes Kommando (`sleep 30` nach 2 s `cmd_timeout` abgeschossen, Update nach 4 s zurück, alle DS `U`) |
| `./t_update.pl` | ALL CHECKS PASSED (Exaktwerte, Browser-Fall, corrupted-cmd) |
| `./t_cgi.pl` (+ `--text`) | ALL CHECKS PASSED — 7 Panels, 14 PNGs, Text 24 Zeilen + Info-Block |
| Live-RRD | Temperatur-DS per `rrdtool tune --minimum <ds>:U` migriert (History erhalten); `t_pipe`/Power-DS behalten Min 0 |
| Daemon + E2E | Neustart sauber, `curl … graph=amdgpu_top … when=day` → 14 Bildreferenzen, 0 ERROR |

Nebenbefund behoben: Alle vier Harnesses luden wegen `use lib`-Reihenfolge die
**installierte** statt der Repo-Kopie von `amdgpu_top.pm` — Reihenfolge getauscht,
Repo gewinnt jetzt.

---

## Nachlauf 2026-11-11 — Upstream-Feedback mikaku (v1.4)

Änderungen sind **ausschließlich CGI-Pfad** (Zeilen ≥ 646: Versionsvergleich
per `version->declare`, AREA-Regex, `graph_colors`-Guard, Spalten-Balancing);
Daemon-/Update-Pfad unverändert gegenüber v1.3.

| Harness | Ergebnis |
|---|---|
| `./t_cgi.pl` (+ `--text`) | ALL CHECKS PASSED (14 PNGs, 0 Fehler) |
| `./t_robust.pl` | ALL CHECKS PASSED |
| `./t_update.pl` | ALL CHECKS PASSED — **aber 2 Vorläufe mit Timing-Flakiness** (Zeilen vorletztes Bucket/Live-Wert in erwartetem Bucket nicht lesbar; exakte Werte alle OK). Update-Pfad code-seitig unverändert → Laufzeit-Umwelt (Minuten-Grenzen-Kollision mit Daemon-eigenem `amdgpu_top`-Aufruf), bei sauberem Wiederholungslauf grün. |
| Live HTTP day+week | je 7 Bildreferenzen, 0 ERROR; Spalten-Delta 3 px (links 1656 / rechts 1659) |
| Visuell | Screenshot: Spalten bündig; Memory-Panel zeigt VRAM/GTT-AREA-Flächen |

Nebenbefunde behoben:

1. **AREA-Regex-Bug (latent seit v1.0):** Regex `/^(AREA|LINE\d)(#.*)?$/`
   passend zur Schreibweise `AREA:#farbe` in `@PANELS` nie → Capacity-
   Backdrops waren still auf LINE2 degradiert. Jetzt `/^(AREA|LINE\d)(?::?(#.*))?$/`.
2. **`graph_colors`-Guard:** Beim CLI-Aufruf `monitorix.cgi "mode=…"` ohne
   CGI-Umgebung (und bei Index-Generierung) ist `graph_colors` stellenweise
   undef; die Inline-Deref in der Built-in-Form überlebt das, die
   @picargs-Form crashte. Guard `|| []` macht beide Pfade robust.
3. CLI-Screenshot-Test rendert schwarzes Theme (`theme_color = black` greift
   ohne `color=`-Env) und überschreibt `www/imgs` — nach CLI-Tests immer per
   HTTP-curl neu erzeugen.

### Folgebericht Nutzer (v1.4.1): weißer Memory-Graph im Black-Theme

Ursache: die durch den Regex-Fix erstmals wirklich gezeichneten hellen
Capacity-Backdrops (GTT total = 122880 MiB → fast volle Plotfläche).
Fix: Helligkeit von `$colors->{bg_color}` (Theme main_bg, immer gesetzt:
white=FFFFFF / black=000000) entscheidet; dunkles Theme → #33334D (GTT) /
#4D4D4D (VRAM). Verifikation: `t_cgi` ALL PASSED; HTTP `color=black` und
`color=white` je 0 ERROR; Screenshots: Black-Theme dezenter dunkler
Hintergrund, White-Theme helles Lavendel-Backdrop wie gehabt.
