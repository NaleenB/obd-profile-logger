# OBDLogger

Diagnostic data logging and early-fault detection for a **2016 Mitsubishi
Outlander 2.2 DiD (4N14)**. Private project.

The goal is preventive: record live engine data and codes continuously, compare
them against factory thresholds, and surface drift **before** something fails.

## Repository layout

| Path | Purpose |
|---|---|
| `Probe/` | macOS probe tool. Discovers the BLE adapter, enumerates what the ECU supports, captures everything to disk. |
| `Core/` | Platform-neutral Swift package: PID definitions, vehicle spec thresholds, health evaluation. Shared by the probe and the forthcoming apps. |

## Verified vehicle facts

Established by probing the car, not assumed:

- Adapter: Viecar BLE, `ELM327 v1.5`, `AT@1` = `ICSolution`, Microchip `IS1678S152`
- Bus: ISO 15765-4 CAN 11-bit / 500 kbps
- Responders: `7E8` engine, `7E9` transmission — **both answer broadcast mode 01**
- Engine supports 26 mode-01 PIDs, nothing above `0x4E`
- **No DPF, EGT, or oil-temperature PIDs.** Not implemented on this ECU.
- No freeze frame, mode 06 unavailable
- Throughput ~8.3 reads/s (~2 Hz per PID across a 4-PID loop)

## Probe usage

```bash
cd Probe
./run.sh                  # scan, connect, prompt for ignition, capture everything
./run.sh --list           # show nearby BLE devices
./run.sh --replay <log>   # re-analyse a recorded raw_log.ndjson offline
./run.sh --self-test      # verify the ELM327 parser
```

Output lands in `Probe/results/<timestamp>/`:

- `probe.json` — capability map, identity, DTCs
- `report.txt` — human summary
- `raw_log.ndjson` — every command and response with timings

`--list`, `--replay` and `--self-test` need no car.

## Battery measurement (default behaviour)

Every normal probe run measures the battery across the start event. There is no
flag for it:

1. Turn the ignition on, then start the engine whenever you like.
2. The probe samples control-module voltage at ~6 Hz and RPM every sixth pass.
3. It detects the crank, captures the minimum voltage, times the recovery, and
   reports charging voltage once running.

Findings are graded against: crank minimum above 9.5 V (below 9.0 V = failing),
charging 13.8-14.5 V running. A voltage read with the ignition on is never
treated as a resting-battery diagnosis.

## Core usage

```bash
cd Core
swift test
```

The health layer distinguishes **factory-sourced limits** (Mitsubishi service
manual data-list items) from **heuristics**, so an inference is never presented
with the authority of a specification.

## Roadmap

1. **Track A** — iOS/macOS app: continuous recording, pending-DTC polling with a
   full-PID snapshot on first sighting, health findings against factory ranges,
   zip export for analysis.
2. **Track B** — UDS `0x22` access to manufacturer data (DPF soot, regeneration
   state), pending DID discovery. Read-only; every DID validated against a
   factory range before use.

## Credits and references

- **2016 Outlander service manual** — factory data-list items and normal ranges.
  https://jdmfsm.info/Auto/Japan/Mitsubishi/Outlander/Manuals/2016/
- **MUT-III SE `.exdf` decryption** — Mohammad-Ali Bandzar's reverse-engineering
  write-up established the bit-reverse + XOR `0xAA` transform.
  https://mohammad-ali.bandzar.com/blog/reverse-engineering-mut-iii-se-decrypting-exdf-files/
  https://mohammad-ali.bandzar.com/blog/reverse-engineering-mut-iii-se-exploring-commondb/
- **ELM327 protocol** — ELM Electronics datasheets; cloned firmware behaves
  differently and is treated as such throughout.
- Thanks to the reviewers who flagged the battery-provenance, BLE write-type and
  reading-staleness issues in the first code review.

## Known limitations

Generic OBD-II on this vehicle cannot see ABS, SRS, AWD or body codes, and cannot
see DPF data. Those need MUT-III or a Mitsubishi-capable tool. This project covers
the engine and transmission only.
