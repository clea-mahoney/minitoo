#!/usr/bin/env python3

from __future__ import annotations

import re
import sys
from pathlib import Path

HEX_RE = re.compile(r"rx\[\d+\]:\s+([0-9a-fA-F ]+)")

def parse_packets(text: str) -> list[list[int]]:
    packets: list[list[int]] = []
    for match in HEX_RE.finditer(text):
        try:
            packets.append([int(part, 16) for part in match.group(1).split()])
        except ValueError:
            continue
    return packets

def plausible_device_id(value: int) -> bool:
    return 10_000_000 <= value <= 4_000_000_000

def extract_device_id(packet: list[int]) -> int | None:
    if len(packet) < 14 or packet[0] != 0x01 or packet[3] != 0x04:
        return None
    if packet[4:7] != [0xBD, 0x55, 0x2B]:
        return None

    data = packet[7:-3]
    if len(data) < 4:
        return None

    candidates = [
        int.from_bytes(bytes(data[0:4]), "little"),
        int.from_bytes(bytes(data[0:4]), "big"),
    ]
    for candidate in candidates:
        if plausible_device_id(candidate):
            return candidate
    return None

def main() -> int:
    if len(sys.argv) != 2:
        print("usage: parse-device-id-log.py /tmp/divoom-send.log", file=sys.stderr)
        return 64

    path = Path(sys.argv[1])
    if not path.exists():
        return 1

    for packet in reversed(parse_packets(path.read_text(encoding="utf-8", errors="replace"))):
        device_id = extract_device_id(packet)
        if device_id is not None:
            print(device_id)
            return 0
    return 1

if __name__ == "__main__":
    raise SystemExit(main())
