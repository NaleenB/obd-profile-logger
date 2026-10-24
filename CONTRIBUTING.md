# Contributing

Useful contributions, in rough order of value:

1. **A vehicle profile.** A new car supported by data alone.
2. **Protocol findings.** A quirk in your adapter or ECU, written up in
   `docs/protocol-notes.md`.
3. **A port.** Python, Android, Rust — the profile format exists to make this
   realistic.
4. **Bug reports** with a raw log attached.

## Adding a vehicle

Read `profiles/README.md` first. The short version:

1. Find out which diagnostic service your ECU implements. Sweep it.
2. Build the profile, either generated or by hand.
3. **Validate every parameter against a known physical value.** A coolant
   reading that matches the dashboard is evidence; a plausible number is not.
4. Record how you validated it in the pull request.

Profiles that carry `observed` values from a real capture are much easier to
review, because a reviewer can check the arithmetic.

## Rules that are not negotiable

**Read-only.** No service `2E`, `2F` or `31`. No actuator tests, no forced
regenerations, no coding changes. A wrong write can damage a vehicle, and this
tool is used by people who are not mechanics.

**Do not commit manufacturer software.** No service manuals in bulk, no
decrypted diagnostic databases, no extracted binary dumps. A profile contains
identifiers, offsets, scaling and item names — factual protocol metadata. That
is the line.

**Provenance must be honest.** If a limit comes from a factory manual, cite the
item number. If it is a rule of thumb, say so and explain the reasoning. Never
present an inference as a specification.

**A check may only use a fresh reading taken under the stated condition.** Do not
let a stale or mismatched value flow into a verdict.

## Style

- Swift: no third-party dependencies. `swift test` must pass.
- Python in `tools/`: standard library only, Python 3.9+.
- Prefer a clear comment explaining *why* over one restating *what*.

## Before opening a pull request

```bash
cd Core && swift test
cd ../Probe && ./run.sh --self-test
git diff --check
```

If you changed decoding behaviour, add a test using a real captured frame.
Tests built from the author's own car data have caught every regression in this
project so far.

## Roadmap

Planned, in rough order. Nothing here is committed to a date.

| Item | Notes |
|---|---|
| ~~Session history~~ | done — sessions list, per-session export, share-all, delete |
| ~~Profile-driven standard PIDs~~ | done — both shipped profiles define their own signal list and scaling |
| ~~Profile picker~~ | done — then removed: identification is automatic and there is no picker |
| ~~Background recording~~ | done — verified on the iPhone with the screen locked |
| ~~CI~~ | done — Core tests, Probe self-test and both app builds on every push |
| Quiet mode on hardware | the loop degrades once the car stops answering; not yet watched going quiet and waking again |
| Stale-peripheral recovery | the rescan fallback is shared by connect and reconnect; not yet induced on a phone |
| Baseline learning | compare a drive against the car's own normal, not just factory limits |
| More vehicle profiles | the whole point — `profiles/generic/iso15765-can.json` is the template |

## Not in scope

Writing to an ECU, actuator tests, forced regenerations, ABS/SRS/body modules, and
anything that requires a credential or a manufacturer subscription.
