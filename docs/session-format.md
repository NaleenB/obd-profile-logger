# Session format

One directory per recording, under Application Support:

```
OBDLogger/Sessions/<yyyyMMdd-HHmmss>-<4 hex>/
  manifest.json
  samples.ndjson
  events.ndjson
```

Session IDs are UTC timestamps plus a random suffix, so they sort chronologically
and two sessions in the same second cannot collide. An existing directory is
never reused.

NDJSON is canonical. CSV is never written as a source of truth; export produces a
ZIP of these three files unchanged.

## manifest.json

Written at start, rewritten at stop with `finishedAt` and counts.

| Field | Meaning |
|---|---|
| `schemaVersion` | format version (2) |
| `sessionID` | directory name |
| `startedAt`, `finishedAt` | wall clock, ISO 8601 |
| `appVersion` | build that wrote the session |
| `vehicleProfileID` | profile assumed by this build, or null |
| `adapterName`, `adapterIdentifier` | BLE identity, when known |
| `supportedPIDs` | null when capability discovery was not run |
| `notes` | free-form, including what the recording did **not** cover |

Nothing is invented. A value the app could not determine is omitted or null.

## samples.ndjson

One successful observation per line. There is deliberately no "all signals at
one instant" record: each PID is read separately, so each carries its own time
and its own presence.

Standard PID observation (`pid` present):

```json
{"schemaVersion":2,"elapsedMs":1234,"wallTime":"2026-10-23T03:21:07.512Z",
 "pid":"23","name":"Rail","value":337.2,"unit":"bar","raw":"41230D2C"}
```

Manufacturer observation (`pid` absent, `service`/`lid` present):

```json
{"schemaVersion":2,"elapsedMs":9100,"wallTime":"2026-10-23T03:21:16Z",
 "service":"21","lid":"11","itemNumber":155,
 "name":"Soot loading by summation","value":2.6,"unit":"g/L","raw":"6111141F34061D"}
```

Schema 2 makes `pid` optional precisely so manufacturer data can be recorded
without being forced into a standard PID field.

| Field | Meaning |
|---|---|
| `elapsedMs` | monotonic milliseconds since session start |
| `wallTime` | for correlation only; never used for ordering |
| `pid` | two-digit hex, standard PIDs only |
| `service`, `lid` | diagnostic service and local identifier, manufacturer data |
| `itemNumber` | manufacturer data-list item, when the profile supplies one |
| `name`, `unit` | human labels, as displayed |
| `value` | engineering value, already scaled |
| `raw` | response payload, so a decoding bug can be corrected later |

**A failed read writes nothing.** It does not write zero, and it does not repeat
the previous value. A missing sample means the read failed, which is information.

`elapsedMs` comes from an uptime clock, so a wall-clock adjustment (timezone,
NTP, user change) cannot make session time go backwards.

## events.ndjson

```json
{"schemaVersion":1,"elapsedMs":9004,"wallTime":"2026-10-23T03:21:14Z",
 "type":"dtc_snapshot","details":{"complete":"true","summary":"No codes in any module"}}
```

Types: `session_started`, `session_stopped`, `adapter_connected`,
`adapter_disconnected`, `recording_interrupted`, `dtc_snapshot`, `error`.

Lifecycle events are idempotent: `finish` writes at most one
`session_stopped`, and a repeated stop is a no-op.

### DTC snapshots

Emitted on the first completed scan, when the code set changes, and when scan
completeness changes — not on every poll. Details include per-module codes and a
per-query outcome (`ok`, `empty`, `no_reply`, `rejected`, `malformed`), so
"no codes" is never confused with "did not answer".

## Recording behaviour under failure

A sample write failure stops the session immediately and marks it failed. The
partial directory is kept and remains exportable, but the app never reports it as
successfully saved. Finalisation likewise reports `.incomplete` when the stop
event or manifest could not be written.

## Known limitation

DTC scans cover the engine (`7E0`) and transmission (`7E1`) only. ABS, SRS, AWD
and body controllers do not answer generic OBD on this vehicle. When a module
does not reply the scan is marked `complete=false` and the module is named in
`incompleteModules`; the result is never presented as a full-vehicle scan.

## Export

`SessionArchive.export` produces a ZIP at a unique temporary path using
`NSFileCoordinator`'s uploading mode. The source directory is only read. The UI
shares that ZIP through the system share sheet and discards the temporary copy
afterwards.
