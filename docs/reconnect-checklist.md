# Connection recovery — hardware checklist

Purpose: prove that a dropped BLE link costs samples, not the session, and that
"the car stopped answering" stays distinguishable from "the phone lost the
adapter".

The reconnect and gap logic is unit-tested, but none of it has been exercised
on the phone while the car was moving, and that is the condition that matters:
one `session_started` and one `session_stopped` around a drive is the whole
claim.

**Status: not yet run on hardware.**

## What the app is supposed to do

- A link loss while recording keeps the session open. It retries every 2 s,
  backing off to 10 s, for ten minutes (`LiveModel.beginReconnect`).
- A successful retry writes `adapter_reconnected` with `attempt`,
  `protocolDetected` and `requestHeader`, then resumes polling.
- Silence for 10 s writes `data_gap`. The gap closes only on a sample
  (`data_resumed`) or deliberately (`data_gap_ended` with a `reason`).
- At ten minutes it gives up honestly: `data_gap_ended` reason `link_down`,
  then `session_stopped` reason `reconnect_timeout`.
- A reconnect is not a new session. Profile, battery cycle and the open gap
  survive it; a half-finished DTC scan does not.

## Before you start

1. Note the build version on screen; it must match `manifest.json` afterwards.
2. Note whether the app was foreground, screen locked, or suspended at the
   moment of each drop. The log cannot tell you that, and Scenarios C and D
   depend on it.
3. Have a passenger hold the phone. Do not operate it while driving.

## Scenario A — the phone leaves the car, the car keeps answering

The primary test: engine running, car moving 40–60 km/h, adapter powered.

1. Confirm tiles are updating and recording is on.
2. Passenger takes the phone ~30 m away for 60–90 s, then returns.
3. Keep driving for at least two minutes after reconnection.
4. Stop the recording normally.

Expected in `events.ndjson`, in order:

| Event | Expected |
|---|---|
| `data_gap` | `quietSeconds` at or above 10 |
| `adapter_disconnected` | a CoreBluetooth reason, e.g. "The connection has timed out unexpectedly." |
| `adapter_reconnected` | `attempt` at least 2; `requestHeader` `7E0`; `protocolDetected` `6` or `A6`, never `A0` |
| `data_resumed` | `gapSeconds` covers the whole outage, not just the retry |
| `sweep_completed` | a later cycle answers the same number of LIDs |

Checks:

- exactly one `session_started` and one `session_stopped`;
- manufacturer samples (`"service":"21"`) on **both** sides of the gap — if only
  mode `01` resumes, the header is wrong (session `20261029-150006` is what
  that looks like);
- exactly one `battery_test` for this engine cycle — a Bluetooth dropout must
  not reset the battery monitor;
- no `profile_changed` back to `generic-iso15765-can` — a reconnect preserves
  the car it identified.

## Scenario B — the car stops answering first

The common end-of-drive case: the adapter stays powered while the ECU sleeps,
and this clone drops BLE a few seconds after the last answer.

1. Drive, park, switch the engine off, leave the phone in the car.
2. Wait at least 15 minutes without touching the app.

Expected: `data_gap`, `adapter_disconnected`, possibly `adapter_reconnected`
while the car is still silent, then one `data_gap_ended` with
`reason: recording_stopped` at the ten-minute idle rule, and `session_stopped`
`idle_timeout`. No `data_resumed`, no samples after the engine stopped, and the
end `trip_snapshot` says `source: cached` with `maxAgeSeconds`.

This has two halves already observed, and a third that is not.
`20261105-124750-3E44` is the idle half: the gap ended as
`recording_stopped` after ten minutes, with no samples after the engine
stopped. `20261104-164839-8C42` is the reconnect half: two drops while the car
was silent, a reconnect inside each, and the gap kept open until a real sample
arrived. Neither had a car that stayed silent through the deadline — that is
what this scenario adds, so record it the first time it happens.

## Scenario C — the ten-minute window expires

1. Connect and start recording with the car running.
2. Take the phone out of range and stay away for 12 minutes.
3. Bring the app to the foreground.

Expected: `data_gap_ended` `reason: link_down` and `session_stopped`
`reason: reconnect_timeout`; the screen says "Adapter disconnected". The
session is finished, not left open. If nothing is written until the app is
foregrounded, record that: it means the deadline did not run while suspended.

## Scenario D — the drop happens while the app is suspended

This is the shape of the unfinished session `20261107-100221-5A20`: the screen
was locked, the link dropped 19 s after the car went quiet, and the file ends at
`adapter_disconnected` with no `session_stopped` and no `finishedAt`.

1. While recording, lock the screen, take the phone out of range for 60 s, then
   bring the app back to the foreground.

Pass means either the reconnect completes (`adapter_reconnected` +
`data_resumed`) or the session is finished with an explicit reason.

Known current behaviour this test is meant to confirm or refute:
`appDidBecomeActive()` only calls `checkForStall()`, which requires
`phase == .connected`, and a drop leaves it `.reconnecting`. Nothing adopts an
unfinished session at launch either — `init()` loads the generic profile and
starts clean. So if iOS terminates the app during the drop, that session stays
unfinished forever and no event says so. If the app was only suspended, the
reconnect task resumes when the app does.

Do not accept "unfinished with no reason" as a pass. If it happens, the fix is
one of: adopt and close an unfinished session at launch, or restart the
reconnect when the app becomes active with `phase == .reconnecting`.

## Scenario E — the adapter returns under a new identity (optional)

Reconnecting to a remembered peripheral UUID can fail if the dongle
re-advertises as a different peripheral. Mid-drive, unplug and replug the dongle
so it power-cycles while the app is retrying.

Expected: `adapter_reconnected` with `adapterRescanned: true` once the scan
finds it. A reconnect that never rescans, or one that keeps failing against a
stale peripheral for ten minutes, is the fallback this checks.

## Pull the result and check it

```bash
./tools/pull-ios-sessions.sh
cd sessions/<session-id>
jq -r '.type' events.ndjson | sort | uniq -c
jq -c 'select(.type|test("^(session_started|session_stopped|data_gap|data_resumed|data_gap_ended|adapter_disconnected|adapter_reconnected)$"))' events.ndjson
jq -c 'select(.type=="adapter_reconnected") | .details' events.ndjson
```

When the car kept answering, a session passes when it has one start, one stop,
at least one gap, a `data_resumed` whose `gapSeconds` covers the outage,
manufacturer samples after that timestamp, and no second `battery_test`.

## What to send back

- the build version and session id;
- which scenario(s) ran, with the event lines above;
- whether the app was foreground, locked or suspended at each drop;
- anything the car did that the log does not explain.

Do not commit the session: it contains driving data and is gitignored by
design.
