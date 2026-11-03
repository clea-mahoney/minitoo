import importlib.util
import json
from pathlib import Path
import sys
import threading
import time
import unittest
import urllib.error
import urllib.request
from unittest.mock import patch

APP = Path(__file__).resolve().parents[1] / "apps/live-studio"
sys.path.insert(0, str(APP))
spec = importlib.util.spec_from_file_location("studio_server", APP / "server.py")
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)


class StudioTests(unittest.TestCase):
    def setUp(self):
        server.STOP.clear()
        server.RESULTS.clear()
        server.PENDING.update(runs=[], name="", seq=0)
        self.http = server.http.server.ThreadingHTTPServer(("127.0.0.1", 0), server.Handler)
        self.base = f"http://127.0.0.1:{self.http.server_port}"
        self.thread = threading.Thread(target=self.http.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.close)

    def close(self):
        server.STOP.set()
        self.http.shutdown()
        self.http.server_close()
        self.thread.join()

    def post(self, value, **headers):
        request = urllib.request.Request(self.base + "/update", data=json.dumps(value).encode(),
            headers={"Content-Type": "application/json", **headers})
        with urllib.request.urlopen(request) as response:
            return response.status, json.loads(response.read())

    def result(self, seq):
        with urllib.request.urlopen(self.base + f"/delivery/{seq}") as response:
            return json.loads(response.read())

    def test_queue_does_not_claim_delivery(self):
        status, response = self.post({"text": "Hello", "color": "#3CC9A4"})
        self.assertEqual(status, 202)
        self.assertEqual(self.result(response["seq"])["state"], "queued")

    def test_latest_queued_message_supersedes_old_message(self):
        _, first = self.post({"text": "First"})
        _, second = self.post({"text": "Second"})
        self.assertEqual(self.result(first["seq"])["state"], "superseded")
        self.assertEqual(self.result(second["seq"])["state"], "queued")

    def test_invalid_content_is_rejected(self):
        for value in ([], {"text": "x" * 301}, {"runs": [{"text": "Hi", "color": "invalid"}]}, {"runs": "invalid"}):
            with self.subTest(value=type(value).__name__):
                with self.assertRaises(urllib.error.HTTPError) as caught:
                    self.post(value)
                self.assertEqual(caught.exception.code, 400)

    def test_other_websites_cannot_send_local_messages(self):
        with self.assertRaises(urllib.error.HTTPError) as caught:
            self.post({"text": "Hi"}, Origin="https://example.com")
        self.assertEqual(caught.exception.code, 403)

    def test_transport_error_reaches_controller_without_retry_storm(self):
        _, response = self.post({"text": "Test"})
        with patch.object(server.media_sender, "push", side_effect=RuntimeError("No ACK")) as push:
            worker = threading.Thread(target=server.push_worker, daemon=True)
            worker.start()
            try:
                deadline = time.monotonic() + 3
                while time.monotonic() < deadline and self.result(response["seq"])["state"] != "failed":
                    time.sleep(0.03)
                result = self.result(response["seq"])
                self.assertEqual(result, {"state": "failed", "error": "No ACK"})
                time.sleep(0.5)
                self.assertEqual(push.call_count, 1)
            finally:
                server.STOP.set()
                worker.join(2)

    def test_sender_name_is_not_drawn(self):
        from PIL import Image
        first = server.render([{"text": "Hello", "color": "#3CC9A4"}], "First person")
        pixels = Image.open(first).tobytes()
        second = server.render([{"text": "Hello", "color": "#3CC9A4"}], "Second person")
        self.assertEqual(pixels, Image.open(second).tobytes())


if __name__ == "__main__":
    unittest.main()
