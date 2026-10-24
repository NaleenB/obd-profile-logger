# Session format

A session begins when the adapter connects and ends when it disconnects. There is
no separate Record button: connecting is the intent to record. A connection that
produces no samples still yields a session, which is useful evidence in itself.

One directory per recording, under Application Support:

```
OBDLogger/Sessions/<yyyyMMdd-HHmmss>-<4 hex>/
  manifest.json
  samples.ndjson
  events.ndjson
  profile.json      the decoding rules used, copied in at session start
```

Session IDs are UTC timestamps plus a random suffix, so they sort chronologically
and two sessions in the same second cannot collide. An existing directory is
never reused.

NDJSON is canonical. CSV is never written as a source of truth. Export archives the
whole session directory unchanged — `manifest.json`, `samples.ndjson`,
`events.ndjson`, **and `profile.json`** — so a session remains decodable after the
app ships a different profile. Sharing everything at once stages the sessions under
a single `OBDLogger-sessions/` root and archives that.

## manifest.json

Written at start, rewritten at stop with `finishedAt` and counts.

| Field | Meaning |
|---|---|
| `schemaVersion` | format version (3) |
| `sessionID` | directory name |
| `startedAt`, `finishedAt` | wall clock, ISO 8601 |
| `appVersion` | build that wrote the session |
| `vehicleProfileID` | profile assumed by this build, or null |
| `adapterName`, `adapterIdentifier` | BLE identity, when known |
| `supportedPIDs` | full capability set discovered during the session; null when discovery never succeeded |
| `capabilityDiscovery` | `succeeded` or `failed` — written at stop, so a cold start that resolved once the ECU woke records `succeeded` |
| `profileHash` | SHA-256 of the profile JSON used, so a decode change is detectable |
| `timezoneOffsetSeconds` | offset from UTC, so `wallTime` is unambiguous |
| `odometerStartKm` / `odometerEndKm` | from the engine ECU; needed for soot-per-km and regen interval |
| `ambientTempC` | intake air temperature before the engine started, used as an ambient proxy |
| `coldSoakHours` | hours since the previous session ended, when known |
| `notes` | free-form, including what the recording did **not** cover |

Nothing is invented. A value the app could not determine is omitted or null.

## samples.ndjson

One successful observation per line. There is deliberately no "all signals at
one instant" record: each PID is read separately, so each carries its own time
and its own presence.

Standard PID observation (`pid` present):

```json
{"schemaVersion":3,"elapsedMs":1234,"wallTime":"2026-10-23T03:21:07.512Z",
 "pid":"23","name":"Rail","value":337.2,"unit":"bar","raw":"41230D2C"}
```

Manufacturer observation (`pid` absent, `service`/`lid` present):

```json
{"schemaVersion":3,"elapsedMs":9100,"wallTime":"2026-10-23T03:21:16Z",
 "service":"21","lid":"11","itemNumber":155,
 "name":"Soot loading by summation","value":2.6,"unit":"g/L","raw":"6111141F34061D"}
```

Schema 2 made `pid` optional precisely so manufacturer data can be recorded
without being forced into a standard PID field.

| Field | Meaning |
|---|---|
| `elapsedMs` | monotonic milliseconds since session start |
| `wallTime` | for correlation only; never used for ordering |
| `pid` | two-digit hex, standard PIDs only |
| `service`, `lid` | diagnostic service and local identifier, manufacturer data |
| `itemNumber` | manufacturer data-list item, when the profile supplies one |
| `name`, `unit` | human labels, as displayed; `unit` is omitted when unknown |
| `value` | engineering value, already scaled |
| `raw` | response payload, so a decoding bug can be corrected later |

**A failed read writes nothing.** It does not write zero, and it does not repeat
the previous value. A missing sample means the read failed, which is information.

`elapsedMs` comes from an uptime clock, so a wall-clock adjustment (timezone,
NTP, user change) cannot make session time go backwards.

## events.ndjson

```json
{"schemaVersion":3,"elapsedMs":9004,"wallTime":"2026-10-23T03:21:14Z",
 "type":"dtc_snapshot","details":{"complete":"true","summary":"No codes in any module"}}
```

Types: `session_started`, `session_stopped`, `adapter_connected`,
`adapter_disconnected`, `adapter_reconnected`, `recording_interrupted`,
`battery_test`, `data_gap`, `data_resumed`, `regen_started`, `regen_ended`,
`sweep_completed`, `trip_snapshot`, `dtc_snapshot`, `error`.

`data_gap` / `data_resumed` bracket a stretch where the vehicle stopped
answering while recording continued — usually ignition off. The adapter stays
connected in that case, because OBD pin 16 is permanent battery power and the
dongle never loses power; only the ECU sleeps.

`adapter_connected` is written after the session starts, so it always appears.

`regen_started` and `regen_ended` bracket a DPF regeneration. Detection uses the
filter temperature from the live block (above 450 °C starts, below 300 °C for ten
seconds ends) rather than the ECU's own flag, because the flag sits in a block
that refreshes once per ~90 s sweep while the temperature is sampled several
times a second. `regen_ended` carries the duration, peak temperature, and the soot
figure before and after where available. A regeneration still running when the
session ends is closed with `truncated: true` rather than dropped.

When the link drops during a recording, the session is **not** closed. The app
records `adapter_disconnected`, then `data_gap`, and retries the connection for up
to ten minutes with backoff. On success it writes `adapter_reconnected` and
continues the same session, so a walk out of range and back produces one file
rather than two. If the ten minutes expire the session is stopped with reason
`reconnect_timeout`.

`adapter_disconnected` means the *link* dropped (out of range, unplugged, module
reset). It does **not** by itself stop the recording: the app retries and, if it
reconnects, continues the same session. The session ends only on an intentional
disconnect, a reconnect timeout, or the idle rule.

Exactly one `session_started` is written per session, by `RecordingSession.start`,
with caller metadata merged in. The link is dropped automatically after ten minutes without a successful sample,
so a session left running with the ignition off does not sit open forever. That
is recorded as `adapter_disconnected` with `reason: idle_timeout`. Quitting the
app writes `session_stopped` with `reason: app_quit`.

Lifecycle events are idempotent: `finish` writes
at most one `session_stopped`, and a repeated stop is a no-op.

### DTC snapshots

Emitted on the first completed scan, when the code set changes, and when scan
completeness changes — not on every poll. Details include per-module codes and a
per-query outcome (`ok`, `empty`, `no_reply`, `rejected`, `malformed`,
`header_error`), so "no codes" is never confused with "did not answer".

`header_error` means the adapter did not acknowledge the module header, so the
query was **never sent**. That case is recorded rather than answered, because a
reply without the intended header would come from whichever module was addressed
last and would be attributed to the wrong ECU.

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

## Deleting

Sessions can be deleted individually or all at once from the Sessions view, with
confirmation. The session currently being recorded is never offered for deletion,
and "delete all" skips it.

Deleting removes the directory, not just the entry: the NDJSON and manifest are
gone. Export is unaffected because it only ever reads the source.

## Export

`SessionArchive.export` produces a ZIP at a unique temporary path using
`NSFileCoordinator`'s uploading mode.

`SessionArchive.exportAll` does the same for several sessions at once: it stages
copies under a single root folder and archives that, so the result is
`OBDLogger-sessions/<session>/…` rather than a scatter of sibling directories.
Sources are only read. The session currently being recorded is excluded, because
a partial session in a shared archive invites wrong conclusions. The source directory is only read. The UI
shares that ZIP through the system share sheet and discards the temporary copy
afterwards.
