import importlib.util
import os
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import patch

from PIL import Image
import zstandard as zstd

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("media", ROOT / "core/media.py")
media = importlib.util.module_from_spec(spec)
spec.loader.exec_module(media)


class MediaTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.folder = Path(self.temp.name)
        self.image = self.folder / "image.png"
        Image.new("RGB", (160, 128), (20, 80, 120)).save(self.image)

    def test_full_width_round_trip_and_window(self):
        payload = media.encode(self.image)
        kind, count, speed, rows, cols, size = struct.unpack(">BBHBBI", payload[:10])
        self.assertEqual((kind, count, rows, cols), (0x25, 1, 8, 10))
        self.assertEqual(size, len(payload) - 10)
        self.assertLessEqual(zstd.get_frame_parameters(payload[10:]).window_size, 131072)
        decoded = zstd.ZstdDecompressor().decompress(payload[10:])
        self.assertEqual(decoded, Image.open(self.image).convert("RGB").tobytes())

    def test_animation_limit_and_square_compatibility(self):
        frames = [Image.new("RGB", (160, 128), color) for color in ("red", "green", "blue")]
        animation = self.folder / "animation.gif"
        frames[0].save(animation, save_all=True, append_images=frames[1:], duration=200, loop=0)
        payload = media.encode(animation, width=128, max_frames=2)
        self.assertEqual(payload[1], 2)
        self.assertEqual(payload[4:6], bytes([8, 8]))
        self.assertEqual(len(zstd.ZstdDecompressor().decompress(payload[10:])), 2 * 128 * 128 * 3)

    def test_chunk_order_and_payload_reassembly(self):
        payload = bytes(range(256)) * 5 + b"end"
        announce, chunks = media.commands(payload)
        self.assertEqual(announce, b"\x8b\x00" + struct.pack("<I", len(payload)))
        for seq, chunk in enumerate(chunks):
            self.assertEqual(chunk[:2], b"\x8b\x01")
            self.assertEqual(struct.unpack("<I", chunk[2:6])[0], len(payload))
            self.assertEqual(struct.unpack("<H", chunk[6:8])[0], seq)
            self.assertLessEqual(len(chunk[8:]), 256)
        self.assertEqual(b"".join(chunk[8:] for chunk in chunks), payload)

    def fake_helper(self, *, acknowledge=True, fail=False):
        log = self.folder / "helper.log"
        # Old ACKs must not satisfy a new transfer.
        log.write_text("delegate: rx[13]: " + media.ACK.hex(" ") + "\n")
        helper = self.folder / "dv"
        helper.write_text('''#!/usr/bin/env python3
import pathlib,sys
log = pathlib.Path(%r)
commands = pathlib.Path(sys.argv[2]).read_text().splitlines()
start = bytes.fromhex(commands[0])[:2] == b'\\x8b\\x00'
with log.open('a') as stream:
    if %r:
        stream.write('  write failed: 0xerror\\n')
    elif start:
        stream.write('delegate: rx[5]: 01 07 00 04 8b\\n')
        stream.write('delegate: rx[6]: 55 00 01 ec 00 02\\n')
    elif %r:
        stream.write('delegate: rx[13]: 01 09 00 04 bd 55 13 01 05 00 38 01 02\\n')
''' % (str(log), fail, acknowledge))
        helper.chmod(0o755)
        return helper, log

    def test_transfer_waits_for_request_and_fresh_ack(self):
        helper, log = self.fake_helper()
        result = media.send(media.encode(self.image), dv=helper, log=log)
        self.assertTrue(result["acknowledged"])

    def test_old_ack_does_not_hide_missing_new_ack(self):
        helper, log = self.fake_helper(acknowledge=False)
        original = media.Replies.wait
        def short_wait(self, expected, timeout):
            return original(self, expected, 0.1)
        with patch.object(media.Replies, "wait", short_wait):
            with self.assertRaisesRegex(TimeoutError, "acknowledge"):
                media.send(media.encode(self.image), dv=helper, log=log)

    def test_failed_bluetooth_write_is_an_error(self):
        helper, log = self.fake_helper(fail=True)
        with self.assertRaisesRegex(RuntimeError, "Bluetooth transfer failed"):
            media.send(media.encode(self.image), dv=helper, log=log)

    def test_split_log_line_is_not_lost(self):
        log = self.folder / "partial.log"
        log.write_text("")
        replies = media.Replies(log)
        log.write_text("delegate: rx[11]: 01 07 00")
        replies.poll()
        with log.open("a") as stream:
            stream.write(" 04 8b 55 00 01 ec 00 02\n")
        replies.wait(media.REQUEST, 0.1)

    def test_helper_restart_fails_transfer(self):
        log = self.folder / "reset.log"
        log.write_text("old helper output\n")
        replies = media.Replies(log)
        log.write_text("")
        with self.assertRaisesRegex(RuntimeError, "restarted"):
            replies.poll()


if __name__ == "__main__":
    unittest.main()
