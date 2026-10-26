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
  profile.json      the decoding rules used; replaced when a profile resolves
```

Session IDs are the recording device's local time plus a random suffix, so a
session recorded at breakfast is dated that morning. Two sessions in the same
second cannot collide, because an existing directory is never reused.

Older sessions were named in UTC; list ordering is therefore taken from
`startedAt` (UTC) rather than from the directory name, which keeps the list
correct across a timezone change or a daylight-saving transition. The manifest
records `timezoneOffsetSeconds` alongside, so local time is always recoverable.

NDJSON is canonical. CSV is never written as a source of truth. Export archives the
whole session directory unchanged — `manifest.json`, `samples.ndjson`,
`events.ndjson`, **and `profile.json`** — so a session remains decodable after the
app ships a different profile. Sharing everything at once stages the sessions under
a single `OBDLogger-sessions/` root and archives that.

## manifest.json

Written at start, rewritten whenever profile, discovery or odometer state
changes, and rewritten at stop with `finishedAt` and counts.

| Field | Meaning |
|---|---|
| `schemaVersion` | format version (4) |
| `sessionID` | directory name |
| `startedAt`, `finishedAt` | wall clock, ISO 8601 |
| `appVersion` | build that wrote the session |
| `vehicleProfileID` | profile in effect when the session ended; `generic-iso15765-can` when none matched |
| `adapterName`, `adapterIdentifier` | BLE identity, when known |
| `supportedPIDs` | full capability set discovered during the session; null when discovery never succeeded |
| `capabilityDiscovery` | `succeeded` or `failed` — written at stop, so a cold start that resolved once the ECU woke records `succeeded` |
| `profileMatch` | `calibration`, `vin`, `agreement`, `none`, or `override` (development only) — written at stop |
| `profileHash` | SHA-256 of the profile JSON that describes every manufacturer sample in the session |
| `timezoneOffsetSeconds` | offset from UTC, so `wallTime` is unambiguous |
| `odometerStartKm` / `odometerEndKm` | from the engine ECU; needed for soot-per-km and regen interval. The start value is written as soon as it is read, which is usually after recording starts because service `0x21` only answers once the car is identified |
| `ambientTempC` | intake air temperature before the engine started, used as an ambient proxy |
| `coldSoakHours` | hours since the previous session ended, when known |
| `notes` | free-form, including what the recording did **not** cover |

Nothing is invented. A value the app could not determine is omitted or null.

The manifest is rewritten whenever one of these becomes known during the session,
not only when it closes. A session that is killed mid-recording therefore still
describes what its samples were decoded with — which is the session most worth
reading later. `finishedAt` absent means the recording did not close cleanly.

## samples.ndjson

One successful observation per line. There is deliberately no "all signals at
one instant" record: each PID is read separately, so each carries its own time
and its own presence.

Standard PID observation (`pid` present):

```json
{"schemaVersion":4,"elapsedMs":1234,"wallTime":"2026-10-23T03:21:07.512Z",
 "pid":"23","name":"Rail","value":337.2,"unit":"bar","raw":"41230D2C"}
```

Manufacturer observation (`pid` absent, `service`/`lid` present):

```json
{"schemaVersion":4,"elapsedMs":9100,"wallTime":"2026-10-23T03:21:16Z",
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
{"schemaVersion":4,"elapsedMs":9004,"wallTime":"2026-10-23T03:21:14Z",
 "type":"dtc_snapshot","details":{"complete":"true","summary":"No codes in any module"}}
```

Types: `session_started`, `session_stopped`, `adapter_connected`,
`adapter_disconnected`, `adapter_reconnected`, `recording_interrupted`,
`battery_test`, `data_gap`, `data_resumed`, `data_gap_ended`,
`regen_started`, `regen_ended`,
`sweep_completed`, `trip_snapshot`, `dtc_snapshot`, `profile_changed`,
`profile_disagreement`, `startup_timing`, `app_lifecycle`, `error`.

`startup_timing` records where connection time went. It exists because "the
phone connects slowly" is otherwise unfalsifiable.

Every field is a **stage duration**, so no subtraction is needed to find the slow
one; only `totalMs` is cumulative.

| Field | Stage |
|---|---|
| `startMs` | Bluetooth power-on and manager start |
| `adapterDiscoveryMs` | retrieving the remembered adapter, or scanning for one |
| `adapterConnectMs` | connecting, discovering services, subscribing |
| `adapterRescanned` | `true` when the remembered adapter failed and a scan was needed |
| `elmInitMs` | `ATE0`/`ATL0`/`ATS0`/`ATH0` and the protocol choice |
| `selectHeaderMs`, `mutReplyMs`, `restoreHeaderMs` | the manufacturer probe of service `0x21`, split by command |
| `probeTotalMs` | that probe in total |
| `capabilityDiscoveryMs` | asking which standard PIDs are supported |
| `totalMs` | connection start to recording started |

Two header commands costing seconds rather than milliseconds is the signature of
an adapter still busy with an earlier reply, which is a different problem from a
slow car and is invisible in a single total.

A second `startup_timing` event with `phase: first_sample` records
`sinceConnectMs`: connection start to the first successful observation. It uses
the timestamp of that observation, not the end of the polling cycle, so later
manufacturer reads cannot inflate it. That is the number a driver feels.

`profile_changed` marks the boundary where a vehicle profile was applied. The app
starts on generic OBD and may identify the car while recording, once the ECU wakes
or the engine runs. It carries `from`, `to`, `method` and `reason`. No manufacturer
sample is written before that event, so the archived `profile.json` describes every
one of them; samples are self-describing (`name`, `unit`, `value`, `raw`) either
way.

`sweep_completed` closes a cycle only after the final identifier's request has
reached a terminal outcome — a parseable reply or a timeout. An attempt is
recorded immediately before the `21xx` request, not while its header is being
configured, so a connection lost before the request leaves that identifier
unattempted rather than counting a request that was never sent. `attempted`,
`answered` and `missing` therefore describe exactly one pass over the profile's
identifiers; neither a timeout nor a dropped connection is carried into the next
cycle.

`profile_disagreement` means the profile matched by calibration or VIN, but a
required discriminator (engine speed) did not agree with the ECU's own reading. The
profile is kept — calibration is authoritative — and the evidence is recorded so a
wrong byte offset can be found without re-driving the car.

`data_gap` / `data_resumed` bracket a stretch where the vehicle stopped
answering while recording continued — usually ignition off. The adapter stays
connected in that case, because OBD pin 16 is permanent battery power and the
dongle never loses power; only the ECU sleeps.

`data_resumed` means a sample from the vehicle arrived. `data_gap_ended` means
the gap closed for any other reason, and carries `reason`: `link_down` (the
reconnect window expired), `stalled` (the polling loop was reset) or
`recording_stopped`. A gap that spans a disconnect is preserved until a genuine
sample arrives, so the outage is not erased merely because the link returned and
the first sample is never claimed as proof that data was available while the link
was down. A link is established only after notification subscription completes,
not merely when the serial characteristic is found; if a connection attempt drops
before that, it is a failed attempt to retry, not a second established-link loss.
The retry loop is replaced only after the old attempt has released the shared
transport. A superseded attempt checks ownership after every await and stops
before its fallback scan or connection, so a user disconnect cannot be followed
by a stale link behind the "Not connected" screen; only the attempt that still
owns the transport closes it.

While a gap is open the app stops asking the full signal list — every request
would go unanswered — and instead reads the adapter's own supply voltage (`ATRV`,
which needs no ECU) plus engine speed once every three seconds. That single real
PID read is what detects the car waking up; a successful read ends the gap and
restores the full cycle by itself.

`app_lifecycle` records `active`, `inactive` and `background` transitions, with
`quietSeconds` — how long the car had been silent at that moment. It exists
because "the app froze" is otherwise indistinguishable from "the car was off":
the last file, plus the phone's system log, settled exactly that question once.

The screen also says when the car has gone quiet: after five seconds without a
sample the status line reads *Vehicle not responding*, the values dim and show
their age, so a parked car does not look like a hung app. Those values are the
last ones the car gave — they are never refreshed or zeroed to fill the gap.

`adapter_connected` is written after the session starts, so it always appears.

`regen_started` and `regen_ended` bracket a DPF regeneration. Detection uses the
filter temperature from the profile's declared live block (above 450 °C starts,
below 300 °C for ten seconds ends) rather than the ECU's own flag, because the
flag sits in a block that refreshes once per ~90 s sweep while the temperature is
sampled several times a second. `regen_ended` carries the duration, peak
temperature, and the profile-declared soot figure before and after where
available. A regeneration still running when the session ends is closed with
`truncated: true` rather than dropped.

When the link drops during a recording, the session is **not** closed. The app
records `adapter_disconnected` and retries the connection for up to ten minutes
with backoff. An open data gap stays open across the reconnect; if the outage
crosses the ten-second threshold while reconnecting, `data_gap` is emitted. Only
a genuine sample after reconnection produces `data_resumed`. Reconnection uses
the same remembered-adapter-first, rescan-on-failure path as the first connection
(`adapter_rescanned` in `adapter_reconnected`), so a peripheral that has gone
stale cannot block recovery. On success it writes `adapter_reconnected` and
continues the same session, so a walk out of range and back produces one file
rather than two. If the ten minutes expire, a still-open gap ends with
`reason: link_down` and the session is stopped with reason `reconnect_timeout`.

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
Sources are only read. The session currently being recorded is excluded from
both single and multi-session export, because a partial session in a shared
archive invites wrong conclusions. The UI shares the ZIP through the system share
sheet and discards the temporary copy afterwards.
