# Umgebungs- und Datenquellen-Analyse (Step 0)

Aufnahme: 2026-11-09, Live-System (Fedora 44 Container-Image, SELinux disabled)

## Versionsstand
| Komponente | Version / Pfad |
|---|---|
| amdgpu_top | v0.10.5, `/usr/bin/amdgpu_top` |
| Monitorix | 3.16.0, `/usr/bin/monitorix` (RPM) |
| Perl | 5.42.3 |
| JSON::PP | 4.16 (core) — `JSON::XS` nicht installiert |
| RRDs | 1.9 |
| GPU | 1× Radeon 8060S Graphics (Strix Halo, gfx1151, APU) |

Monitorix-Konfiguration (relevant):
- `base_lib = /var/lib/monitorix/`, `base_dir = /var/lib/monitorix/www/`
- `include_dir = /etc/monitorix/conf.d`
- `httpd_builtin`: enabled, Port 8080, user/group `nobody`
- Daemon läuft (systemd) als root → fdinfo-Lesezugriff; Service aktuell inactive (Start in Step 4)

## Datenquellen-Aufrufe (verifiziert)

| Aufruf | Verhalten | Inhalt |
|---|---|---|
| `amdgpu_top -J -n 1` | One-Shot, Exit 0, ~1,1 s, 1 Zeile JSON (~7 KB) | **ALLES**: GRBM, GRBM2, Info, Sensors, Total fdinfo, VRAM, fdinfo, gpu_activity, gpu_metrics, xdna_fdinfo |
| `amdgpu_top -J -n 1 -s 500` | wie oben, ~0,6 s | identisch vollständig |
| `amdgpu_top -J --dump` | One-Shot, Exit 0, ~43 ms | Info+Sensors+VRAM+gpu_activity+gpu_metrics, **ohne** GRBM/GRBM2/fdinfo |
| `amdgpu_top -J -n 1 --no-pc` | One-Shot | GRBM und GRBM2 = `null`, Rest vorhanden |
| `amdgpu_top -J` (ohne -n) | Endlos-Streaming, 1 Dokument/Zeile/Sekunde | verworfen (terminiert nicht) |
| `amdgpu_top -J --process` | Textoutput, `-J` wird ignoriert | verworfen |

`-n <u32>` = max. Iterationen des JSON-Modus (0 = Endlos); `-s <ms>` = Refresh-Periode.

## Samples (in `samples/`)
Alle eine Zeile, mit `jq` validiert:
- `oneshot.json` (7070 B) — `amdgpu_top -J -n 1`, Hauptreferenz für Schema/Parser-Tests
- `nopc.json` (6298 B) — `amdgpu_top -J -n 1 --no-pc` (GRBM/GRBM2 null → Toleranztest)
- `dump.json` (5266 B) — `amdgpu_top -J --dump` (reicht für statischen Info-Block)

## JSON-Top-Level (oneshot.json)
```
{ "ROCm version": null,
  "amdgpu_top_version": {major, minor, patch},
  "devices": [ 1 Device ] }
```
Device-Keys: GRBM, GRBM2, Info, Sensors, Total fdinfo, VRAM, fdinfo, gpu_activity, gpu_metrics, xdna_fdinfo

Wichtige Fallen (in `plan.md` §1.3/§4 details):
- GRBM2-Teilschlüssel enthalten **Doppel-Leerzeichen**, z. B. `"Command Processor -  Compute"`, `"Command Processor -  Fetcher"`
- `gpu_metrics.temperature_*` sind ×100 (3275 → 32,75 °C); `average_*_power` sind mW (55957 → ~56 W)
- Bei APU: die meisten gpu_metrics-Fan/junction/memory-Werte `null`; `gpu_activity.Memory` kann `null` sein
- `Sensors."CPU Core freq"` = Array 16× `{core_id, thread_id, cur_freq, min_freq, max_freq}`
- `fdinfo` hat verschachteltes `{pid: {name, usage: {name, usage: {…12 Felder}}}}` — usage teils doppelt genestet (im Parser prüfen!)
- `pci`/PCI-Strings: `PCI` in Info, `PCIe Link Speed` i. d. R. null bei APU

## Referenz-Monitorix-Architektur (verifiziert aus Quelltext)
- `/usr/bin/monitorix` lädt Module rein namenhaft: `use $g qw(${g}_init ${g}_update)` für Einträge in `graph_name` mit `graph_enable->{$g}=y`
- `/var/lib/monitorix/www/cgi/monitorix.cgi` analog `use $gn qw(${gn}_cgi)` (läuft als nobody!)
- conf.d-Merge unterstützt `additional_graph_name` (Anhängen an graph_name) + Hash-Merge für `<graph_enable>`/`<descriptions>`
- Plot-Titel: `$config->{graphs}->{'_amdgpu_top'.$n}`; Bildname: `$package$k$n[ z].<when>.png`
- Vorbildmodule: `/usr/lib/monitorix/nvidiagpu.pm` (Multi-Plot, map, show_current_values), `/usr/lib/monitorix/amdenergy.pm` (RRD-Grundgerüst, .bak-Rotation)
- Eingebaut exists bereits `/usr/lib/monitorix/amdgpu.pm` (sysfs-basiert) → unser Modul `amdgpu_top` kollisionsfrei
