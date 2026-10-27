# Device session archive

Sessions pulled from the iPhone live here and are **not tracked by git**
(`.gitignore` ignores everything in this directory except this file). They are
raw vehicle data and can be large.

Layout: `<session-id>/` mirrors the app's session directory — `manifest.json`,
`samples.ndjson`, `events.ndjson` and `profile.json`.

Pull with:

```bash
./tools/pull-ios-sessions.sh [<udid>]
```

Each pull refreshes sessions already present. NDJSON is append-only, so a
session that was still recording when it was first pulled is completed by a
later pull; a session deleted from the phone stays here.

`.last-pull` and `.pull-log` record when this archive was last synchronised.
