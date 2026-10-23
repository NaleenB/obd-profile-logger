# OBDProbe

A one-shot BLE probe for the ELM327 dongle in the 2016 Outlander diesel. It exists
to answer two questions before any app gets built:

1. Which BLE serial port does the dongle actually talk on?
2. Which OBD-II PIDs does the 4N14 engine ECU actually answer?

Everything it learns is written to a `probe.json` in the same shape the real
OBDLogger app will use, and every command/response is logged so protocol
behaviour can be diagnosed later.

## Running it

```bash
cd OBDLogger/Probe
./run.sh                 # build, then probe
```

The tool will:

1. Scan for BLE devices and pick the OBD adapter (serial service advertised, or a
   recognisable name).
2. Connect and identify the serial characteristic.
3. Read the BLE Device Information strings.
4. Run the adapter handshake (`ATZ`, `ATE0`, `ATL0`, `ATS0`, `ATH0`).
5. Print **TURN THE IGNITION ON NOW** and poll `0100` until the ECU answers.
6. Pin the protocol to `ATSP6` (CAN 11-bit / 500 kbps).
7. Read VIN, calibration ID, CVN via mode 09.
8. Walk the supported-PID bitmaps (`0100` … `01C0`).
9. Read every advertised PID once, to separate "supported" from "actually answers".
10. Snapshot MIL state, stored / pending / permanent DTCs, and the freeze frame.

## If device selection fails

```bash
./run.sh --list                      # see every nearby BLE device with RSSI
./run.sh --device IOS-Vlink          # force a name match
```

An explicit `--device` bypasses the "looks like an OBD adapter" heuristic.

## Other options

| Flag | Purpose |
|---|---|
| `--scan-seconds <n>` | scan duration, default 6 |
| `--ignition-wait <n>` | seconds to wait for the ECU, default 180 |
| `--skip-ignition` | adapter-only probe, no ECU queries |
| `--out <dir>` | results directory |
| `--self-test` | verify the ELM327 parser against captured responses |

## Output

Results land in `results/<yyyyMMdd-HHmmss>/`:

- `probe.json` — adapter identity, protocol, VIN, supported PIDs, decoded values, DTCs
- `report.txt` — human-readable summary
- `raw_log.ndjson` — every command with its raw bytes, hex, and round-trip time

## First-run note

macOS will ask for Bluetooth permission the first time. The binary is wrapped in
a minimal `.app` bundle by `run.sh` specifically so the grant attaches to
`OBDProbe` rather than to your terminal. If you deny it by accident:

System Settings → Privacy & Security → Bluetooth → enable OBDProbe.

## Known quirks of this dongle

Confirmed by probing (`ATI`, `AT@1`) rather than assumed:

- Firmware reports `ELM327 v1.5`; `AT@1` returns `ICSolution` — a clone board.
- `ATDPN` returns `6` without the usual `A` (auto-detect) prefix.
- Advertises both `FFF0/FFF1/FFF2` and the Microchip Transparent UART service;
  only the FFF0 path was confirmed live.
- Multi-frame responses (mode 09 VIN, long DTC lists) may be unreliable on v1.5
  clones. The parser handles the frame format, but the hardware may still lie.
