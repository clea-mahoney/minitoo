import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]


class SessionTests(unittest.TestCase):
    def test_stop_restores_existing_pause_and_face_without_uploading(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            app = root / "apps/live-studio"
            clauddy = root / "apps/clauddy"
            app.mkdir(parents=True)
            (clauddy / "lib").mkdir(parents=True)
            home = root / "home"
            (home / ".clauddy").mkdir(parents=True)
            pause = home / ".clauddy/disabled"
            pause.write_text("manual pause survives\n")
            state = root / "state"
            state.write_text("working 123 token\n")
            shutil.copy2(ROOT / "apps/live-studio/run.sh", app / "run.sh")
            (clauddy / "lib/clauddy-lib.sh").write_text('''
CLAUDDY_CONFIG_DEFAULT=unused
CLAUDDY_MINITOO_MAC=unused
clauddy_load_config() { :; }
clauddy_lock_acquire_or_die() { mkdir "$HOME/.clauddy/lock"; }
clauddy_lock_release() { rmdir "$HOME/.clauddy/lock"; }
clauddy_start_daemon() { :; }
clauddy_stop_daemon() { :; }
''')
            (clauddy / "clauddy").write_text('#!/bin/bash\necho temporary > "$HOME/.clauddy/disabled"\n')
            (clauddy / "set-clauddy-state.sh").write_text('#!/bin/bash\necho "$1" > "$HOME/restored-face"\n')
            (app / "server.py").write_text('''import signal,time
from pathlib import Path
import os
running=True
def stop(*args):
    global running
    running=False
signal.signal(signal.SIGTERM,stop)
Path(os.environ['HOME'],'server-ready').touch()
while running: time.sleep(.02)
''')
            for file in (app / "run.sh", clauddy / "clauddy", clauddy / "set-clauddy-state.sh"):
                file.chmod(0o755)
            environment = dict(os.environ, HOME=str(home), CLAUDDY_HOOK_STATE_FILE=str(state))
            environment.pop("FIREBASE_DB_URL", None)
            process = subprocess.Popen([str(app / "run.sh")], env=environment,
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline and not (home / "server-ready").exists():
                    time.sleep(.02)
                self.assertTrue((home / "server-ready").exists())
                process.terminate()
                process.communicate(timeout=5)
                self.assertEqual(pause.read_text(), "manual pause survives\n")
                self.assertEqual((home / "restored-face").read_text().strip(), "working")
                self.assertFalse((home / ".clauddy/lock").exists())
                self.assertFalse((home / ".clauddy/live-studio.pids").exists())
            finally:
                if process.poll() is None:
                    process.kill()
                    process.communicate(timeout=5)


if __name__ == "__main__":
    unittest.main()
