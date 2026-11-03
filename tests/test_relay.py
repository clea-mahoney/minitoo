import importlib.util
from pathlib import Path
import sys
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "apps/live-studio"
sys.path.insert(0, str(APP))
spec = importlib.util.spec_from_file_location("studio_relay", APP / "firebase-relay.py")
relay = importlib.util.module_from_spec(spec)
spec.loader.exec_module(relay)


class Finished(BaseException):
    pass


class RelayTests(unittest.TestCase):
    def check_sequence(self, baseline, following):
        snapshots = iter((baseline, following, following))
        client = Mock()
        client.call.side_effect = lambda path, *args: next(snapshots) if path == relay.MESSAGE_PATH else None
        with patch.object(relay, "Firebase", return_value=client), patch.object(relay, "request"), \
             patch.object(relay, "push_local", return_value=77) as push, \
             patch.object(relay, "local_result", return_value={"state": "acknowledged"}), \
             patch.object(relay, "log_message") as log, \
             patch.object(relay.time, "sleep", side_effect=[None, None, Finished()]):
            with self.assertRaises(Finished):
                relay.main()
            push.assert_called_once_with(following)
            log.assert_called_once()
            self.assertEqual(log.call_args.args[0], following)

    def test_startup_skips_saved_message_and_delivers_the_next_send(self):
        self.check_sequence({"ts": 1, "text": "old"}, {"ts": 2, "text": "new"})

    def test_empty_startup_still_delivers_the_first_new_message(self):
        self.check_sequence(None, {"ts": 2, "text": "new"})

    def test_deliberate_history_replay_after_startup_is_allowed(self):
        self.check_sequence({"ts": 20, "text": "current"}, {"ts": 10, "text": "previous"})


if __name__ == "__main__":
    unittest.main()
