#!/usr/bin/env python3
"""Generate a vehicle profile JSON from decoded MUT-III SE data.

The point of this tool is reproducibility: a contributor with a different
Mitsubishi can run the same extraction and end up with a profile in the same
shape, rather than hand-typing a few hundred parameters.

Inputs are decrypted .exdf files (see Research/NOTES.md) plus an optional probe
capture used to record which parameters were actually observed on the car.

This script only emits factual protocol metadata: identifiers, byte offsets,
scaling and item names. No proprietary binaries are embedded.
"""

import argparse
import json
import re

UNIT_NAMES = {
    "1000002": "%",
    "1000004": "deg CA",
    "1000005": "km/h",
    "1000006": "kPa",
    "1000007": "mA",
    "1000008": "ms",
    "1000009": "mV",
    "1000010": "rpm",
    "1000012": "degC",
    "1000019": "km",
    "1000035": "g",
    "1000074": "us",
    "1000081": "mm3/st",
    "1000082": "mm3/st",
    "1000083": "MPa",
    "1000087": "g/L",
    "1000088": "cc",
}


def load_names(path):
    text = open(path, encoding="utf-8", errors="replace").read()
    names = {}
    for match in re.finditer(r'<item_name iid="(\d+)">(.*?)</item_name>', text, re.S):
        english = re.search(r"<N>(.*?)</N>", match.group(2), re.S)
        number = re.search(r"<no>(.*?)</no>", match.group(2), re.S)
        if english:
            names[match.group(1)] = (
                english.group(1).strip(),
                number.group(1).strip() if number else "",
            )
    return names


def load_ecu(path):
    """Returns (item_lang_id -> qual_id, qual_id -> block definition)."""
    text = open(path, encoding="utf-8", errors="replace").read()

    item_to_qual = {}
    for match in re.finditer(r"<item_list>(.*?)</item_list>", text, re.S):
        lang = re.search(r"<item_lang_id>(\d+)</item_lang_id>", match.group(1))
        qual = re.search(r"<qual_id>(\d+)</qual_id>", match.group(1))
        if lang and qual:
            item_to_qual[lang.group(1)] = qual.group(1)

    quals = {}
    for match in re.finditer(r'<qual_id qid="(\d+)">(.*?)</qual_id>', text, re.S):
        qid, body = match.group(1), match.group(2)
        sid = re.search(r"<sid>(.*?)</sid>", body)
        lid = re.search(r"<lid>(.*?)</lid>", body)
        if not (sid and lid):
            continue

        params = []
        for param in re.finditer(r'<param_list pid="-?\d+">(.*?)</param_list>', body, re.S):
            block = param.group(1)

            def get(tag, default=None):
                found = re.search(r"<%s>(.*?)</%s>" % (tag, tag), block)
                return found.group(1) if found else default

            try:
                params.append({
                    "byte": int(get("byte_pos", -1)),
                    "length": int(get("byte_len", 1)),
                    "factor": float(get("factor", "1") or 1),
                    "offset": float(get("offset", "0") or 0),
                    "unitId": get("unit_id", "0"),
                })
            except (TypeError, ValueError):
                continue

        quals[qid] = {"sid": int(sid.group(1)), "lid": int(lid.group(1)), "params": params}

    return item_to_qual, quals


# Standard OBD-II signals this build polls. Scaling is data, not code:
# value = raw * factor + offset, with `bytes` read big-endian.
STANDARD_SIGNALS = [
    {"pid": "0C", "name": "Engine speed",            "unit": "rpm",   "bytes": 2, "factor": 0.25,   "offset": 0,   "decimals": 0},
    {"pid": "0D", "name": "Vehicle speed",           "unit": "km/h",  "bytes": 1, "factor": 1.0,    "offset": 0,   "decimals": 0},
    {"pid": "05", "name": "Coolant temperature",     "unit": "degC",  "bytes": 1, "factor": 1.0,    "offset": -40, "decimals": 0},
    {"pid": "0B", "name": "Intake MAP",              "unit": "kPa",   "bytes": 1, "factor": 1.0,    "offset": 0,   "decimals": 0},
    {"pid": "10", "name": "Mass air flow",           "unit": "g/s",   "bytes": 2, "factor": 0.01,   "offset": 0,   "decimals": 2},
    {"pid": "04", "name": "Calculated load",         "unit": "%",     "bytes": 1, "factor": 0.392157, "offset": 0, "decimals": 0},
    {"pid": "23", "name": "Fuel rail pressure",      "unit": "bar",   "bytes": 2, "factor": 0.1,    "offset": 0,   "decimals": 1},
    {"pid": "42", "name": "Control module voltage",  "unit": "V",     "bytes": 2, "factor": 0.001,  "offset": 0,   "decimals": 2},
    {"pid": "0F", "name": "Intake air temperature",  "unit": "degC",  "bytes": 1, "factor": 1.0,    "offset": -40, "decimals": 0},
    {"pid": "33", "name": "Barometric pressure",     "unit": "kPa",   "bytes": 1, "factor": 1.0,    "offset": 0,   "decimals": 0},
]

# ISO 15765-4 CAN 11/500. ELM `ATSP` value 6; 0 means auto-detect.
TRANSPORT = {
    "elmProtocol": "6",
    "description": "ISO 15765-4 (CAN 11/500)",
    "modules": [
        {"name": "ECM", "requestHeader": "7E0", "responseHeader": "7E8"},
        {"name": "TCM", "requestHeader": "7E1", "responseHeader": "7E9"},
    ],
}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--ecu", required=True)
    parser.add_argument("--lang", required=True)
    parser.add_argument("--capture", help="probe.json from a service 0x21 sweep")
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    names = load_names(args.lang)
    item_to_qual, quals = load_ecu(args.ecu)

    observed = {}
    if args.capture:
        probe = json.load(open(args.capture))
        answered = probe.get("vehicle", {}).get("sweep_21", {}).get("answered", {})
        for lid_hex, frame_hex in answered.items():
            observed[int(lid_hex, 16)] = bytes.fromhex(frame_hex)

    blocks = {}
    for lang_id, (label, item_no) in names.items():
        qid = item_to_qual.get(lang_id)
        if not qid:
            continue
        qual = quals.get(qid)
        if not qual or qual["sid"] != 0x21:
            continue

        lid = qual["lid"]
        frame = observed.get(lid)

        for param in qual["params"]:
            if param["byte"] < 0:
                continue
            entry = {
                "itemNumber": int(item_no) if item_no.isdigit() else None,
                "name": label,
                "byte": param["byte"],
                "length": param["length"],
                "factor": param["factor"],
                "offset": param["offset"],
            }
            unit = UNIT_NAMES.get(param["unitId"])
            if unit:
                entry["unit"] = unit

            if frame is not None:
                chunk = frame[param["byte"]: param["byte"] + param["length"]]
                if len(chunk) == param["length"]:
                    raw = int.from_bytes(chunk, "big")
                    entry["observed"] = {
                        "raw": raw,
                        "value": raw * param["factor"] + param["offset"],
                    }

            bucket = blocks.setdefault(lid, [])
            # The source data repeats some parameters inside a block; identical
            # name/offset/scaling entries are the same parameter twice.
            identity = (entry["name"], entry["byte"], entry["length"],
                        entry["factor"], entry["offset"])
            if any((e["name"], e["byte"], e["length"], e["factor"], e["offset"]) == identity
                   for e in bucket):
                continue
            bucket.append(entry)

    profile = {
        "schemaVersion": 1,
        "id": "mitsubishi-outlander-2016-4n14",
        "manufacturer": "Mitsubishi",
        "model": "Outlander",
        "year": 2016,
        "engine": "4N14 2.2 DiD",
        "market": "AU",
        "service": {
            "readByLocalIdentifier": "21",
            "readByIdentifier": None,
        },
        "transport": TRANSPORT,
        "standard": STANDARD_SIGNALS,
        "notes": [
            "Service 0x22 is not implemented by this ECU; it replies NRC 0x11.",
            "Byte offsets are absolute within the response frame, counting the 0x61 "
            "service byte and the local identifier. Established empirically.",
            "Generated from decrypted MUT-III SE data plus an on-car capture.",
        ],
        "blocks": [
            {"lid": "%02X" % lid, "parameters": sorted(params, key=lambda p: p["byte"])}
            for lid, params in sorted(blocks.items())
        ],
    }

    with open(args.out, "w", encoding="utf-8") as handle:
        json.dump(profile, handle, indent=2, sort_keys=False)
        handle.write("\n")

    total = sum(len(b["parameters"]) for b in profile["blocks"])
    seen = sum(
        1 for b in profile["blocks"] for p in b["parameters"] if "observed" in p
    )
    print(f"wrote {args.out}")
    print(f"  {len(profile['blocks'])} local identifiers, {total} parameters")
    print(f"  {seen} parameters carry an observed value from the capture")


if __name__ == "__main__":
    main()
