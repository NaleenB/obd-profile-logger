# MUT-III SE data extraction — findings

Interoperability research on a vehicle we own. No Mitsubishi binaries or database
files are committed here; only the protocol facts needed to read our own car.

## Method

MUT-III SE stores its diagnostics database in encrypted `.exdf` files. The
transform is per byte: **reverse the bit order, then XOR `0xAA`**. With that
undone, the files are plain XML.

`Research/decrypt_exdf.py` implements the transform. It is our own code.

## Vehicle identification

Our VIN `JMFXLGF6WHZ000651` resolves in `CommonDB/VIN_Search` to:

```
TY 334   KD 2540   MY 17
```

`CommonDB/Vehicle_DB` maps that to `VHCL_ID 40`, `ENGINE_ID U24`,
`CANBUS_ID 2524555` for MY 17.

## The engine ECU does not implement UDS `0x22`

A 1,536-identifier sweep of service `0x22` on `7E0` returned `7F 22 11` for every
single request. NRC `0x11` is *service not supported* — not *identifier out of
range* (`0x31`). So the service itself is absent.

MUT-III instead uses **service `0x21`** (KWP2000 `ReadDataByLocalIdentifier`)
with a **1-byte local identifier**.

## Where the mapping lives

In `DiagDB/Ecu/DIESEL*.exdf`, each display item is an `<item_list>` referencing a
`<qual_id>` that carries:

| Field | Meaning |
|---|---|
| `sid` | service, decimal (`33` = `0x21`) |
| `lid` | local identifier, decimal (`17` = `0x11`) |
| `byte_pos` | offset within the response |
| `byte_len` | width in bytes |
| `factor`, `offset` | scaling |
| `unit_id` | unit reference |
| `bit_mask` | bit extraction, where used |

## Extracted DPF mapping

From `DIESEL4N1_06040200.exdf` (the 4N1x diesel family):

### LID `0x11` — byte 4 and 5

| byte_pos | Item | Name | Scale | Unit |
|---|---|---|---|---|
| 4 | 155 | Soot loading by summation | ×0.05 | g/L |
| 5 | 156 | Soot loading by pressure difference | ×0.05 | g/L |

**Cross-validated:** one byte × 0.05 = 12.75 g/L maximum, which is exactly the
service manual's stated range for items 155/156. Two independent sources agree.

### LID `0x12` — byte 4 and 6

| byte_pos | len | Item | Name | Scale |
|---|---|---|---|---|
| 4 | 2 | 148 | Count of regeneration | ×1, max 65535 |
| 6 | 1 | 116 | Mode of regeneration request | enum, range 1000626 |

Again matching the manual: item 148 is documented as 0–65,535.

## Variant caveat

Five diesel ECU definitions contain the soot item. Two of them place it on
**LID `0x4C`** rather than `0x11`, so the sweep must not assume a single LID.
Sweeping all 256 single-byte identifiers resolves the variant empirically.

## Next step

`./run.sh --sweep-only --service 21 --mode22-seconds 60`

256 requests, about 15 seconds of car time. Look for `61 11 …` and `61 12 …`
responses. Confirm the offsets by checking the decoded soot lands in 0–12.75 g/L
and the regen count is a plausible integer.

Nothing here writes to the ECU: service `0x21` is read-only.

## VERIFIED on the vehicle — 2026-10-23 12:44

`--sweep-only --service 21` with ignition on, engine off, battery 11.8 V.

**256 identifiers tried: 104 answered, 0 silent, 152 rejected with NRC 0x12**
(sub-function not supported). Service `0x21` is confirmed working.

### Offset convention established

Byte offsets are **absolute within the response frame**, counting the `0x61`
service byte and the local identifier. Proven two ways:

| Item | Absolute | Data-relative | Truth |
|---|---|---|---|
| 1 Battery voltage | 12.3 V | 0.0 V | engine off, battery ~12.3 V |
| 2 Engine revolution | 0 rpm | 1625 rpm | engine was off |

Absolute indexing is correct on both. Data-relative fails both.

### DPF values read from the car

| LID | Offset | Signal | Value |
|---|---|---|---|
| `0x11` | 4 | Soot by accumulation | **2.6 g/L** (20 % of 12.75 max) |
| `0x11` | 5 | Soot by pressure difference | **0.3 g/L** |
| `0x12` | 4 (2 bytes) | Regeneration count | **123** |
| `0x12` | 6 | Regeneration requested | **no** |

Sanity: 123 regenerations over ~80,000 km is one per ~650 km, which is typical
for a healthy DPF on this class of vehicle. The two soot estimates disagreeing
(2.6 vs 0.3 g/L) is expected — they are independent models, which is exactly why
the ECU keeps both.

Raw frames: `6111141F34061D` and `6112B1E6007B00E60000000000`.

The decoder is implemented in `Core/Sources/OBDCore/MUT21.swift` with 8 tests
built from these captured frames.
