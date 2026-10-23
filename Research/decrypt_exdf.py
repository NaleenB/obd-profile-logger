#!/usr/bin/env python3
"""Decrypt MUT-III SE .exdf files.

The transform, established by published reverse-engineering of MUT-III SE, is
applied per byte: reverse the bit order, then XOR with 0xAA.

This script is our own implementation. It contains no Mitsubishi data and is
used only for interoperability research against a vehicle we own.

Usage:
    decrypt_exdf.py <input-dir-or-file> <output-dir>
"""

import sys
from pathlib import Path

_REV = bytes(
    int(f"{i:08b}"[::-1], 2) for i in range(256)
)


def decrypt(data: bytes) -> bytes:
    return bytes(_REV[b] ^ 0xAA for b in data)


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__)
        return 2

    src = Path(sys.argv[1])
    dst = Path(sys.argv[2])

    targets = [src] if src.is_file() else sorted(src.rglob("*.exdf"))
    ok = failed = 0

    for path in targets:
        try:
            raw = path.read_bytes()
        except OSError as exc:
            print(f"  ! {path}: {exc}")
            failed += 1
            continue

        plain = decrypt(raw)

        if src.is_file():
            out = dst
        else:
            out = dst / path.relative_to(src)
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_bytes(plain)
        ok += 1

    print(f"{ok} decrypted, {failed} failed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
