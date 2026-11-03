#!/usr/bin/env python3
"""Send images and GIFs through the existing Bluetooth helper, without face uploads."""
from __future__ import annotations

import argparse
import io
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import tempfile
import time

from PIL import Image, ImageOps, ImageSequence
import zstandard as zstd

CORE = Path(__file__).resolve().parent
REQUEST = bytes.fromhex("01 07 00 04 8b 55 00 01 ec 00 02")
ACK = bytes.fromhex("01 09 00 04 bd 55 13 01 05 00 38 01 02")


def encode(image_path: Path, *, width=160, height=128, speed_ms=200, max_frames=24):
    if (width, height) not in ((160, 128), (128, 128)):
        raise ValueError("Supported sizes: 160x128 or 128x128")
    if not 1 <= max_frames <= 255 or not 40 <= speed_ms <= 65535:
        raise ValueError("Use 1..255 frames and 40..65535 milliseconds per frame")
    frames = []
    with Image.open(image_path) as image:
        for source in ImageSequence.Iterator(image):
            rgba = ImageOps.exif_transpose(source).convert("RGBA")
            background = Image.new("RGBA", rgba.size, "black")
            background.alpha_composite(rgba)
            fitted = ImageOps.contain(background.convert("RGB"), (width, height))
            canvas = Image.new("RGB", (width, height), "black")
            canvas.paste(fitted, ((width - fitted.width) // 2, (height - fitted.height) // 2))
            frames.append(canvas.tobytes())
            if len(frames) == max_frames:
                break
    # The firmware requires a 128 KiB Zstandard window, including for animations.
    params = zstd.ZstdCompressionParameters.from_level(17, window_log=17, write_content_size=True)
    compressed = zstd.ZstdCompressor(compression_params=params).compress(b"".join(frames))
    if len(compressed) > 512000:
        raise ValueError("Media is too large. Reduce the frame count or image detail.")
    header = struct.pack(">BBHBBI", 0x25, len(frames), speed_ms, height // 16, width // 16, len(compressed))
    return header + compressed


def commands(payload: bytes):
    total = struct.pack("<I", len(payload))
    announce = b"\x8b\x00" + total
    chunks = [b"\x8b\x01" + total + struct.pack("<H", i // 256) + payload[i:i + 256]
              for i in range(0, len(payload), 256)]
    return announce, chunks


class Replies:
    """Read only fresh receive traffic; handle split frames and split log lines."""
    def __init__(self, log: Path):
        self.log = log
        stat = log.stat()
        self.inode, self.offset = stat.st_ino, stat.st_size
        self.lines = ""
        self.received = bytearray()

    def poll(self):
        stat = self.log.stat()
        if stat.st_ino != self.inode or stat.st_size < self.offset:
            raise RuntimeError("Bluetooth helper restarted during transfer")
        with self.log.open("rb") as stream:
            stream.seek(self.offset)
            self.lines += stream.read().decode("utf-8", errors="replace")
            self.offset = stream.tell()
        complete = self.lines.split("\n")
        self.lines = complete.pop()
        for line in complete:
            if "FATAL:" in line or "write failed:" in line or "LOOPBACK" in line:
                raise RuntimeError("Bluetooth transfer failed; inspect the helper log")
            match = re.search(r"delegate: rx\[\d+\]: ([0-9a-fA-F ]+)$", line)
            if match:
                self.received.extend(bytes.fromhex(match.group(1)))
        # Replies are tiny. Bound memory even during a noisy connection.
        if len(self.received) > 65536:
            del self.received[:-4096]

    def wait(self, expected: bytes, timeout: float):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            self.poll()
            index = self.received.find(expected)
            if index >= 0:
                del self.received[:index + len(expected)]
                return
            time.sleep(0.03)
        raise TimeoutError("Device did not acknowledge the media transfer" if expected == ACK
                           else "Device did not request the media data")


def send(payload: bytes, *, dv=None, log=None, delay_ms=12):
    dv = Path(dv or os.environ.get("DIVOOM_DV", CORE / "dv"))
    log = Path(log or os.environ.get("DIVOOM_LOG", "/tmp/divoom-send.log"))
    if not 0 <= delay_ms <= 100:
        raise ValueError("Chunk delay must be between 0 and 100 milliseconds")
    replies = Replies(log)
    announce, chunks = commands(payload)
    started = time.monotonic()
    with tempfile.TemporaryDirectory(prefix="minitoo-media-", dir="/tmp") as folder:
        path = Path(folder) / "frames.txt"
        path.write_text(announce.hex(" ") + "\n")
        subprocess.run([str(dv), "rawfile", str(path), "0"], check=True, capture_output=True, timeout=8)
        replies.wait(REQUEST, 5)
        # Use a different filename: the helper consumes FIFO jobs asynchronously.
        chunk_path = Path(folder) / "chunks.txt"
        chunk_path.write_text("\n".join(chunk.hex(" ") for chunk in chunks) + "\n")
        subprocess.run([str(dv), "rawfile", str(chunk_path), str(delay_ms)],
                       check=True, capture_output=True, timeout=8)
        replies.wait(ACK, max(8, len(chunks) * delay_ms / 1000 + 5))
    return {"ok": True, "acknowledged": True, "bytes": len(payload),
            "chunks": len(chunks), "seconds": round(time.monotonic() - started, 3)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image", type=Path)
    parser.add_argument("--square", action="store_true", help="Use the community-tested 128x128 layout")
    parser.add_argument("--speed-ms", type=int, default=200)
    parser.add_argument("--max-frames", type=int, default=24)
    parser.add_argument("--build-only", type=Path, help="Write the payload without Bluetooth access")
    args = parser.parse_args()
    payload = encode(args.image, width=128 if args.square else 160,
                     speed_ms=args.speed_ms, max_frames=args.max_frames)
    if args.build_only:
        args.build_only.write_bytes(payload)
        print(json.dumps({"bytes": len(payload), "output": str(args.build_only)}))
    else:
        print(json.dumps(send(payload)))


if __name__ == "__main__":
    main()
