# Architecture

## Shape

```
profiles/     Vehicle knowledge as data. The extension point for new cars.
Core/         OBDCore  — models, health rules, decoders (no I/O)
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

Sessions are append-only NDJSON plus an events stream:

- `samples.ndjson` — one record per observation, monotonic elapsed ms
- `events.ndjson` — connect, disconnect, gap start/end, DTC snapshot, stop
- `manifest.json` — vehicle profile id, adapter, capability map, app version

Export builds CSV from these; it never stores CSV as the source of truth. A
crash therefore costs at most one line, and any decode bug can be corrected by
re-processing history rather than re-driving the car.

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
