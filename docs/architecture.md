# Architecture

## Shape

```
profiles/     Vehicle knowledge as data. The extension point for new cars.
Core/         OBDCore  — models, health rules, decoders, file recorder
Link/         OBDLink  — BLE transport and ELM327 client (Apple platforms)
App/          SwiftUI app for iOS and macOS
Probe/        macOS CLI used to discover what a vehicle supports
tools/        Offline generators and extraction helpers
docs/         Protocol and design notes, language-agnostic
Research/     How the manufacturer data was obtained
```

`Core` and `Link` are separate Swift packages so a different front end can adopt
them independently. The app project is generated from `App/project.yml` with
XcodeGen, so the repository stores the intent rather than a 3,000-line
`project.pbxproj`.

The important boundary is **`profiles/` versus code**. Everything that differs
between vehicles lives in JSON. Code implements mechanism, not vehicle facts.

## Why profiles are data

Three audiences want the same knowledge in different runtimes:

- the Swift app
- a Python analysis or logging script
- a future Android client

If manufacturer behaviour were encoded as Swift structs, each port would have to
be re-derived and re-verified. As JSON, the verified facts are written once and
consumed everywhere.

## Layers

```
Transport      BLE or WiFi bytes            (platform-specific)
Protocol       ELM327 command/response      (shared)
Decode         profile-driven: lid → values (shared)
Domain         findings, severity, provenance (shared)
UI             SwiftUI / Compose / TUI      (platform-specific)
```

Only the first and last layers should ever need rewriting per platform. A Python
port is realistically: transport + a small ELM327 reader + load the same profile.

## Provenance is a first-class rule

Every finding carries where its limit came from:

- `serviceManual(item: 2)` — a factory number
- `heuristic("...")` — a rule of thumb, with its reasoning

The UI must never present the second as the first. This exists because a naive
logger would have reported a healthy battery as failing: 11.8 V measured with
the ignition on is a load artefact, not a resting measurement. Two review
findings in this project were about exactly that class of error.

Related rule: a health check may only use a reading that is **fresh** and taken
under the **stated operating condition**. `ReadingSet.fresh(_:maxAgeMs:)` exists
so a stale or mismatched value cannot silently flow into a verdict.

## Recording model

Sessions are append-only NDJSON plus an events stream. The full on-disk contract
is in [`session-format.md`](session-format.md).

- `samples.ndjson` — one successful observation per line, monotonic elapsed ms
- `events.ndjson` — lifecycle and DTC snapshots
- `manifest.json` — profile id, adapter, app version, coverage notes

Three rules that came out of review:

1. **A failed read writes nothing.** No zeros, no carry-forward of the previous
   value. Absence is information.
2. **Each observation keeps its own timestamp.** Signals are read separately, so
   they are never bundled into a synthetic "all at once" record.
3. **NDJSON is canonical.** Export builds a ZIP; CSV is never the source of
   truth. A crash costs at most one line, and a decode bug can be fixed by
   re-processing history rather than re-driving the car.

DTC scanning is a step-at-a-time state machine interleaved with live polling, so
one complete scan does not block the polling loop for its whole duration. Each
individual request still occupies the serialised adapter, so a timeout delays the
next sample.

## Manufacturer data in the app

The app ships the vehicle profile as a bundle resource and takes three things
from it: the ELM protocol selector, the module headers used for DTC scans, and

- the standard `01` signal list with its scaling (`value = raw * factor + offset`)
- the service `0x21` blocks. Nothing about a specific manufacturer is compiled in: the tile
list, byte offsets and scaling all come from JSON.

A full sweep of 75 local identifiers is stepped one per polling iteration, so it
refreshes in the background over about a minute. Values are cached by `lid:name`.
Highlighted parameters, priority blocks, trip snapshots, odometer and DPF roles
are declared in the profile's optional `roles` block, keeping the choice
reviewable and owned by the vehicle data rather than compiled into the app.

## Graceful degradation

The app must reach a usable state with **any** vehicle that answers an ELM327
adapter. A missing or wrong profile degrades, it does not fail.

| Situation | Behaviour |
|---|---|
| No profile, or profile with no `standard` signals | Generic baseline of classic PIDs is used |
| Profile pins a protocol the car does not speak | Probe `0100`; on silence fall back to `ATSP0` auto-detect |
| Car does not support a listed PID | Capability discovery removes it from the dashboard |
| Capability discovery fails entirely | Nothing is filtered; the full list stays |
| Profile names no modules | DTC scan falls back to `7E0`/`7E1` |
| Module does not answer `03`/`07`/`0A` | Scan is marked incomplete; no codes are invented |
| Adapter has no manufacturer service | Manufacturer sweep is skipped silently |

Nothing in this list reports an error to the user, because none of it is a fault
the driver can act on. The one exception is a recording write failure, which is
surfaced because it silently loses data.

## Profile selection

Selecting a profile is not something a driver should have to think about. The app
starts on generic OBD and applies a manufacturer profile only on evidence:

1. Read VIN (mode `09` PID `02`) and calibration ID (PID `04`).
2. Prefer an exact calibration match, then the longest VIN-prefix match. If a
   calibration ID was read but matches no profile, VIN alone is not enough.
3. Otherwise decode only the evidence blocks declared by bundled profiles and
   require the declared live-data discriminators to agree for three consecutive
   probes.
4. If none resolves, continue on standard OBD and retry on the documented
   schedule while the ECU wakes.

**Answering the service is not evidence that the offsets apply.** Service `0x21`
is a transport: "return block *n*". What block *n* contains is defined by the ECU
software, not the protocol. The MUT-III database shows five diesel ECU variants
where the DPF block sits at LID `0x11` on some and `0x4C` on others. A Triton or
ASX would answer `2111` happily and decode to nonsense under these offsets, which
is worse than no data because it looks plausible.

Hence identity matching rather than capability matching. A profile with neither
`calibrationIDs` nor `vinPrefixes` can still be matched by the live-data route its
`identity` block declares, but answering a manufacturer service alone is never
enough.

There is no picker and no manual override in the interface. An unidentified car
runs on standard OBD only; nothing is decoded with unproven offsets. Identification
is retried while the session runs, so a car that was asleep at connect resolves
once it wakes or the engine runs.

## Extension points

| Want to add | Change |
|---|---|
| A vehicle | add a profile JSON |
| A new decoding rule | extend the profile schema, bump `schemaVersion` |
| A platform | implement transport + UI, reuse profiles and the event model |
| A new signal | add a parameter to the profile, then render it generically |

## Non-goals

- Writing to the ECU. The tool is read-only. No actuator tests, no service
  functions, no coding changes.
- Replacing a manufacturer tool. Generic OBD cannot see ABS, SRS, or body
  modules, and on this vehicle it cannot see DPF data at all through standard
  OBD — that required the manufacturer service, documented separately.
