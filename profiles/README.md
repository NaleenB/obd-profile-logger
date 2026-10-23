# Vehicle profiles

A profile is the only thing you need to support a new vehicle. The code is a
generic engine; **all manufacturer-specific knowledge lives in these JSON files**.

That is deliberate. It means:

- adding a car is a data change, not a code change
- a Python or Android port can reuse the same profiles unchanged
- corrections are reviewable as a small, readable diff

## Layout

```
profiles/
  <manufacturer>/<model>-<year>-<engine>.json
```

Examples:

```
profiles/mitsubishi/outlander-2016-4n14.json
profiles/mitsubishi/triton-2019-4n15.json
```

## Schema

### Top level

| Field | Type | Required | Meaning |
|---|---|---|---|
| `schemaVersion` | int | yes | currently `1` |
| `id` | string | yes | stable unique id, e.g. `mitsubishi-outlander-2016-4n14` |
| `manufacturer` | string | yes | `Mitsubishi` |
| `model` | string | yes | `Outlander` |
| `year` | int | yes | model year |
| `engine` | string | yes | engine code and description |
| `market` | string | no | ISO-ish market code, e.g. `AU` |
| `vinPrefixes` | string[] | no | known VIN prefixes for auto-identification |
| `service` | object | yes | which diagnostic services the ECU implements |
| `notes` | string[] | no | caveats a human needs to know |
| `blocks` | array | no | manufacturer-specific data blocks |

### `service`

```json
{
  "readByLocalIdentifier": "21",
  "readByIdentifier": null
}
```

`readByIdentifier` is `null` when the ECU does not implement service `0x22`.
This matters: on the Outlander, `0x22` returns NRC `0x11` (service not
supported), so probing it wastes time. Record what you found, not what you
expected.

### `blocks`

Each block is one request, keyed by its local identifier.

```json
{
  "lid": "11",
  "parameters": [
    {
      "itemNumber": 155,
      "name": "Soot loading by summation",
      "byte": 4,
      "length": 1,
      "factor": 0.05,
      "offset": 0,
      "unit": "g/L",
      "observed": { "raw": 52, "value": 2.6 }
    }
  ]
}
```

| Field | Meaning |
|---|---|
| `lid` | local identifier, hex string, one byte |
| `byte` | **absolute offset within the response frame**, counting the `0x61` service byte and the LID |
| `length` | width in bytes, big-endian |
| `factor`, `offset` | `value = raw * factor + offset` |
| `unit` | engineering unit; omit when unknown rather than guessing |
| `observed` | optional evidence from a real capture: the raw byte and decoded value |

#### The `byte` convention is not obvious

Offsets are **absolute in the frame**, not relative to the data payload. For a
response `61 11 14 1F 34 06 1D`, byte `4` is `0x34`.

This was established by falsification, not assumption. On the Outlander,
item 1 (battery voltage) decodes to 12.3 V only under absolute indexing, and
item 2 (engine revolution) decodes to 0 rpm with the engine off. Data-relative
indexing yields 0.0 V and 1625 rpm — both wrong. If your vehicle disagrees,
record which convention you verified and why.

## Adding a vehicle

1. Get the vehicle's diagnostic data-list definitions. For Mitsubishi this means
   a decrypted MUT-III SE database; other manufacturers differ.
2. Sweep the identifier space to learn which service and identifiers answer.
   `Probe --sweep-only --service 21` for a one-byte identifier space.
3. Generate or hand-write the profile. For Mitsubishi:

   ```bash
   python3 tools/generate_profile.py \
     --ecu  <decrypted>/DiagDB/Ecu/<ECU>.exdf \
     --lang <decrypted>/DiagDB/DiagLangH.exdf \
     --capture Probe/results/<run>/probe.json \
     --out profiles/mitsubishi/<vehicle>.json
   ```

4. **Validate every parameter against a known physical value before trusting
   it.** A coolant reading of 39 °C while the dash shows 39 °C is proof; a
   plausible-looking number is not.
5. Open a pull request with the profile and a short note describing how you
   validated it.

## What not to commit

Do not commit manufacturer diagnostic software, decrypted databases, or bulk
extracted dumps. Only the profile — identifiers, offsets, scaling and item
names — belongs in this repository. See `docs/protocol-notes.md`.
