# OBDLogger

Diagnostic data logging and early-fault detection for cars, built from a real
problem: a 2016 Mitsubishi Outlander 2.2 DiD whose factory tooling is the only
way to see its diesel particulate filter, and whose generic OBD port hides most
of what matters.

The goal is preventive. Record continuously, compare against real limits, and
surface drift before something fails.

**Status:** research complete; probe working; app records sessions and reads the manufacturer data list.

## What makes it different

Generic OBD-II on this vehicle exposes 26 standard PIDs and nothing about the
DPF. By using Mitsubishi's manufacturer service (`0x21`), this project reads
soot loading, regeneration state, EGT, EGR position, VGT duty and injector
learning through a $25 Bluetooth dongle — verified on the car, not inferred.

```
Soot by accumulation        2.6 g/L   (of 12.75 max)
Distance since regeneration  310 km
Regeneration count           123
Short-interval regens          0      <- DPF is healthy
```

## Design

Vehicle knowledge lives in **JSON profiles**, not code.

```
profiles/     one JSON file per vehicle — the extension point
Core/         models, health rules, profile-driven decoders
Probe/        macOS CLI: discover what a vehicle supports, capture everything
App/          SwiftUI for iOS and macOS: live data, recording, export
tools/        offline generators
docs/         protocol and design notes
Research/     how manufacturer data was obtained
```

That split is deliberate: adding a car should be a data change, and a Python or
Android port should be able to reuse the same profiles and the same protocol
notes without re-deriving anything.

## Read this first

- [`docs/architecture.md`](docs/architecture.md) — how the pieces fit, and the
  provenance rules that stop confident wrong answers
- [`docs/protocol-notes.md`](docs/protocol-notes.md) — ELM327 and Mitsubishi
  quirks, language-agnostic
- [`profiles/README.md`](profiles/README.md) — the profile schema and how to add
  a vehicle
- [`CONTRIBUTING.md`](CONTRIBUTING.md) — including the read-only rule

## Quick start

```bash
cd Probe
./run.sh                # connect, prompt for a start, capture everything
./run.sh --self-test    # parser checks, no car needed
./run.sh --list         # nearby BLE devices
./run.sh --replay results/<run>/raw_log.ndjson
```

Every normal run performs a battery test across the crank as a side effect:
minimum cranking voltage, recovery time, and charging voltage. No extra flag.

```bash
cd Core && swift test   # 38 tests
```

## Principles

- **Read-only.** No writes, no actuator tests, no forced regenerations.
- **Honest provenance.** Every finding says whether it came from a factory
  manual or from a heuristic. An inference never masquerades as a specification.
- **Fresh data only.** A health check may not use a stale or mismatched reading.
- **Frames stay separate.** Several modules answer one OBD request; joining
  their replies invents faults.

## Credits

- **2016 Outlander service manual** — factory data-list items and normal ranges.
  https://jdmfsm.info/Auto/Japan/Mitsubishi/Outlander/Manuals/2016/
- **MUT-III SE reverse engineering** — Mohammad-Ali Bandzar established the
  `.exdf` transform (bit-reverse per byte, XOR `0xAA`) that made the
  manufacturer data readable.
  https://mohammad-ali.bandzar.com/blog/reverse-engineering-mut-iii-se-decrypting-exdf-files/
  https://mohammad-ali.bandzar.com/blog/reverse-engineering-mut-iii-se-exploring-commondb/
- **ELM327** — ELM Electronics datasheets. Clone firmware differs from the
  datasheet in ways that matter; those are documented rather than assumed.

## Licence

MIT. See [`LICENSE`](LICENSE).

## Scope

Engine and transmission over OBD. ABS, SRS, AWD and body modules are not
reachable through generic OBD on this vehicle and are out of scope. Diagnostic
software belonging to any manufacturer is not distributed here.
