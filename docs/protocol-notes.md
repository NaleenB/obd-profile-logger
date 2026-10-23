# Protocol notes

Language-agnostic findings from working with real hardware. A Python or Android
port needs these; they are not Swift details.

## Adapter

Cheap BLE ELM327 clones are the norm. Assume nothing.

### BLE serial profile

Two profiles are commonly exposed; probe both.

| Profile | Notify | Write |
|---|---|---|
| `FFF0` (most clones) | `FFF1` | `FFF2` |
| Microchip Transparent UART | `49535343-ACA3-481C-91EC-D85E28A60318` | `49535343-6DAA-4D02-ABF6-19569ACA69FE` |

The Outlander's Viecar unit advertises no service UUIDs in the advertisement
packet, so scanning by service UUID finds nothing. Connect and inspect GATT.

### Write type

Choose the write type from the characteristic's properties, never assume:

```
if properties contains .write          -> with response
else if properties contains .writeWithoutResponse -> without response
```

Chunk size comes from the negotiated MTU, not a fixed 20 bytes.

### Forget the link or the dongle goes silent

These modules stop advertising while connected. If a previous session left the
link open, the next scan finds nothing and it looks like a hardware fault. Scan
with a retry window of at least a minute before concluding the adapter is absent.

## ELM327 quirks observed

- `AT@1` returns `ICSolution` on clones; `ATI` returns `ELM327 v1.5`. The version
  string is unreliable — v1.5 clones are the most common.
- `ATDPN` may return `6` without the usual `A` (auto-detected) prefix.
- Responses are prompt-terminated with `>`. **Accumulate bytes until `>`**; never
  assume one notification equals one response.
- Multi-frame replies arrive as a length line (`014`) followed by `0:`, `1:` …
  chunks. Real ISO-TP, not one line per frame.
- Echo may or may not be present. Parse tolerantly.
- `ATH1` (headers on) **latches the CAN receive filter** to the last responding
  module on this clone. `ATH0` does not clear it. Restore with `ATAR` then
  `ATSH 7DF`. Consequence: do header scans *last*, or lose the other modules.

## Multiple modules answer one request

A broadcast mode 01 request can be answered by several ECUs. With headers off,
the frames are simply concatenated in the response:

```
4100983B8013    <- engine (7E8)
410088180013    <- transmission (7E9)
```

**Never join these.** Doing so fabricates DTCs and corrupts multi-byte values.
Keep frames separate and pick the intended module. With headers on, the CAN ID
prefix identifies the responder (`7E8` = engine, `7E9` = transmission).

## Services

| Service | Purpose | Notes |
|---|---|---|
| `01` | current data | standard OBD |
| `03` | stored DTCs | |
| `07` | pending DTCs | earliest electrical warning available |
| `0A` | permanent DTCs | |
| `09` | vehicle information | VIN, CalID, CVN; multi-frame |
| `21` | read data by local identifier | **Mitsubishi uses this** |
| `22` | read data by identifier | **not implemented on this ECU** |

Negative response codes worth distinguishing:

| NRC | Meaning | What it tells you |
|---|---|---|
| `11` | service not supported | wrong service entirely |
| `12` | sub-function not supported | right service, wrong identifier size/range |
| `31` | request out of range | right service, that identifier is absent |
| `33` | security access denied | needs unlocking first |

The difference between `11` and `31` is the difference between "wrong
protocol" and "wrong address". Do not collapse them.

## Mitsubishi specifics

- CAN 11-bit / 500 kbps, ISO 15765-4. Pin it with `ATSP6`; auto-detection costs
  seconds on every connect.
- Engine request header `7E0`, response `7E8`.
- Manufacturer data uses service `21` with a **one-byte** local identifier.
  Sweeping `00`–`FF` takes about 15 seconds and is the fastest way to learn what
  a variant supports.
- Byte offsets in manufacturer data are **absolute within the response frame**,
  counting the service byte and LID. Verify this per vehicle; do not assume.
- Five diesel ECU variants exist; the DPF block is on LID `0x11` in some and
  `0x4C` in others. Probe all 256 identifiers rather than trusting one variant.

## What generic OBD cannot see

On this vehicle, standard OBD cannot reach:

- DPF soot, regeneration state, EGT, oil temperature — not implemented as PIDs
- ABS, SRS, AWD, body modules — they do not answer broadcast OBD requests
- Freeze frames (mode `02`) — returns `NO DATA`
- Mode `06` on-board monitors — unavailable

Manufacturer service `0x21` closes some of that gap; the rest needs a
manufacturer tool.

## Read-only

Every command used here reads. Services `2E` (write), `2F` (input/output
control) and `31` (routine control) can change ECU state — a forced DPF
regeneration, for example. Do not send them blind. This project does not.

## DTC scanning across modules

Because several modules answer a broadcast request, DTC reads must be
**addressed per module**, not taken from one concatenated payload:

```
ATH0
ATSH 7E0     ; engine
0101 / 03 / 07 / 0A
ATSH 7E1     ; transmission
0101 / 03 / 07 / 0A
ATSH 7DF     ; restore broadcast
ATAR
```

Rules:

- Keep every module's codes attached to that module. Never merge payloads.
- An empty answer (`43 00`) means "no codes". No answer means **unknown**, and
  the scan is reported as incomplete.
- Do not present a scan as vehicle-wide when a module failed to answer.

ABS, SRS, AWD and body modules do not answer generic OBD on this vehicle and are
deliberately out of scope.
