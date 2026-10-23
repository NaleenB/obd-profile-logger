# OBDLogger

**An ELM327 OBD-II logger for iOS and macOS that also reads manufacturer-specific data.**
Any car works for standard PIDs and fault codes. A vehicle profile adds the data the
manufacturer keeps behind a proprietary service — starting with DPF soot and regeneration
state on a 2016 Mitsubishi Outlander diesel.

[![Platforms](https://img.shields.io/badge/platforms-iOS%2018%20%7C%20macOS%2015-lightgrey)]()
[![Swift](https://img.shields.io/badge/swift-5.9%2B-orange)]()
[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)
[![Dependencies](https://img.shields.io/badge/dependencies-none-success)]()

---

## Generic first, vehicle-specific where it counts

Most OBD apps stop at the standard PID list. On this Outlander that is 26 values and
nothing about the diesel particulate filter — the single most expensive thing to get
wrong on a modern diesel.

This project does both:

| Layer | Coverage | How |
|---|---|---|
| **Standard OBD-II** | Any car with a compliant ELM327 adapter | Modes `01`, `03`, `07`, `0A`, `09` |
| **Vehicle profile** | Per vehicle, loaded from JSON | Manufacturer service, byte offsets, scaling |
| **Included profile** | 2016 Outlander 2.2 DiD (4N14) | Mitsubishi service `0x21` — 276 parameters |

Verified on the car, not inferred:

```
Soot by accumulation        2.6 g/L   (of 12.75 max)
Distance since regeneration  310 km
Regeneration count           123
Short-interval regens          0      <- DPF is healthy
```

Also recovered from the same profile: EGT sensors, EGR position and target, VGT duty
before/after compensation, injector small-injection learning across four cylinders and
five rail pressures, oil dilution, and rail pressure versus target.

## Supported vehicles

| Vehicle | Standard OBD | Manufacturer data | Verified |
|---|---|---|---|
| Mitsubishi Outlander 2016, 2.2 DiD (4N14) | yes | yes — 276 parameters | on car |
| Anything else | yes | no profile yet | — |

Adding a vehicle is a JSON file, not code. See [`profiles/README.md`](profiles/README.md).

## Quick start

Requires Xcode 15+ and an ELM327 adapter (BLE for iPhone; BLE or USB for Mac).

```bash
git clone https://github.com/NaleenB/obd-profile-logger.git
cd OBDLogger

# Discover what your car exposes — no app needed
cd Probe && ./run.sh

# Or run the app
cd ../App && xcodegen generate && open OBDLogger.xcodeproj
```

The probe is the fastest way to find out whether a vehicle supports a manufacturer
service at all: `./run.sh --sweep-only --service 21`.

## What it does

- **Live data** over BLE, with a profile-driven manufacturer panel
- **Recording** to append-only NDJSON: one line per successful observation, each with
  its own monotonic timestamp, plus a manifest and an event stream
- **DTC scanning** with per-module attribution, distinguishing "no codes" from
  "did not answer"
- **Battery test** across every start: cranking minimum, recovery time, charging voltage
- **ZIP export** through the system share sheet

## Design principles

- **Read-only.** No writes, no actuator tests, no forced regenerations. A wrong write
  can damage a vehicle.
- **Honest provenance.** Every finding says whether its limit came from a factory manual
  or a heuristic. An inference never masquerades as a specification.
- **Absence is data.** A failed read writes nothing — no zeros, no carry-forward.
- **Frames stay separate.** Several modules answer one OBD request; merging their
  replies invents faults.

## Repository layout

```
profiles/   per-vehicle JSON — the extension point
Core/       OBDCore: models, health rules, decoders, recorder (no I/O beyond files)
Link/       OBDLink: BLE transport and ELM327 client
App/        SwiftUI app for iOS and macOS
Probe/      macOS CLI for discovery and capture
tools/      offline generators
docs/       architecture, protocol notes, session format
Research/   how the manufacturer data was obtained
```

## Documentation

- [`docs/architecture.md`](docs/architecture.md) — how the pieces fit
- [`docs/protocol-notes.md`](docs/protocol-notes.md) — ELM327 and Mitsubishi quirks, written for any language
- [`docs/session-format.md`](docs/session-format.md) — the on-disk contract
- [`profiles/README.md`](profiles/README.md) — adding a vehicle

## Status

Research complete; probe and app working. The recorder and manufacturer panel are
unit-tested but have not yet been driven on the car. See the roadmap in
[`CONTRIBUTING.md`](CONTRIBUTING.md).

## Scope and disclaimer

Engine and transmission only. ABS, SRS, AWD and body modules do not answer generic OBD
on this vehicle. Not affiliated with Mitsubishi, ELM Electronics, or any diagnostic
software vendor. Use at your own risk; this tool never writes to a vehicle.

## Credits

- **2016 Outlander service manual** — factory data-list items and normal ranges.
  <https://jdmfsm.info/Auto/Japan/Mitsubishi/Outlander/Manuals/2016/>
- **MUT-III SE reverse engineering** — Mohammad-Ali Bandzar established the `.exdf`
  transform (bit-reverse per byte, XOR `0xAA`) that made the manufacturer data readable.
  [Part 1](https://mohammad-ali.bandzar.com/blog/reverse-engineering-mut-iii-se-decrypting-exdf-files/) ·
  [Part 2](https://mohammad-ali.bandzar.com/blog/reverse-engineering-mut-iii-se-exploring-commondb/)
- **ELM327** — ELM Electronics datasheets. Clone firmware diverges from them in ways
  this project documents rather than assumes.

## License

MIT — see [`LICENSE`](LICENSE).
