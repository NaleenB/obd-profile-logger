# First drive — verification checklist

Purpose: prove the recorder, DTC scanner, manufacturer sweep and battery test
against real hardware. Nothing here has run on a car yet.

## Do the first drive on the Mac

The macOS build is already compiled and needs no signing. The iOS build adds
variables — free-provisioning, background behaviour, screen lock — that would
confound a first test. Prove the logic on the laptop, then move to the phone.

The laptop must not sleep. Either keep it plugged in with sleep disabled, or run:

```bash
caffeinate -dimsu
```

## Before you drive

1. Unplug and replug the OBD dongle. These adapters stop advertising while a
   previous link is still open, and a stale link looks exactly like a dead one.
2. Close any other OBD app on your phone.
3. Start the app **with the ignition on and the engine off**. The battery test
   needs to see the start; connecting to an already-running engine yields
   `startObserved: false`, which is correct but useless as a test.

## The sequence

1. Launch the app (`cd App && ./run.sh`), press **Connect**. The first connect
   triggers a macOS Bluetooth permission prompt — allow it. Wait for tiles to
   show values.
2. Confirm the DPF line appears (soot, regeneration count).
3. Press **Record**.
4. Start the engine. This is the battery test — it should register a crank.
5. Drive for at least 10 minutes, including some load and a stop.
6. Press **Stop**.
7. Press **Prepare export**, then **Share ZIP** and save it somewhere you can
   open.

## What to check afterwards

Open the exported ZIP. It should contain `manifest.json`, `samples.ndjson` and
`events.ndjson`.

| Check | Expected |
|---|---|
| `manifest.json` | one `session_started`; `finishedAt` set; `sampleCount` note |
| `samples.ndjson` | many lines, `pid` for standard data, `service`/`lid` for manufacturer data |
| Manufacturer samples | soot, regeneration count, EGT present — not only mode `01` |
| `events.ndjson` | exactly one `session_started`, one `session_stopped`, one `battery_test` |
| `battery_test` | `startObserved: true`, a `crankMinimumVolts`, a `runningVolts` |
| DTC snapshots | `complete: true` means **both** ECM and TCM answered |

## The three things most likely to go wrong

**1. TCM header rejection.** This is the one to watch. `events.ndjson` will
contain `outcome.TCM.stored = header_error` if the clone refuses `ATSH7E1`. That
is a correct, visible result — not a crash — but it means transmission codes are
unavailable on this adapter. Note it and we adapt.

**2. Incomplete DTC scan.** If `summary` says "Incomplete scan — no answer from
TCM", the engine codes are still valid. Do not read it as "the car is clean".

**3. Crank minimum missed.** The app polls voltage roughly twice a second while
the engine is off, which is slower than the probe's ~6 Hz. A very short crank
might be sampled only once. If `crankMinimumVolts` looks implausibly high
(above 12 V) the dip was missed rather than absent.

## What to send back

- The ZIP, or just `manifest.json` and `events.ndjson` if it is large
- A note on whether the TCM reported codes or `header_error`
- Whether the DPF line showed plausible values

Do not commit the session to the repository: it contains timestamps and driving
data. Sessions are gitignored by design.
