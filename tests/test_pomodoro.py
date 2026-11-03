"""Exercise timer phases and cleanup without Bluetooth or Music access."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]


class PomodoroTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        app = self.root / 'apps/pomodoro'
        clauddy = self.root / 'apps/clauddy'
        app.mkdir(parents=True)
        (clauddy / 'lib').mkdir(parents=True)
        self.script = app / 'pomodoro.sh'
        shutil.copy2(ROOT / 'apps/pomodoro/pomodoro.sh', self.script)
        self.log = self.root / 'events'
        self.log.touch()
        self.home = self.root / 'home'
        self.home.mkdir()
        bindir = self.root / 'bin'
        bindir.mkdir()
        (clauddy / 'lib/clauddy-lib.sh').write_text('''
CLAUDDY_CONFIG_DEFAULT=unused
CLAUDDY_MINITOO_MAC=unused
clauddy_require_macos() { :; }
clauddy_ensure_dv_app() { :; }
clauddy_load_config() { :; }
clauddy_note() { echo "$*"; }
clauddy_die() { echo "$*" >&2; exit 1; }
clauddy_dv() { echo "$TEST_BIN/dv"; }
clauddy_audio_takeover() { echo route >> "$TEST_LOG"; echo speakers; }
clauddy_audio_takeover_restore() { echo "restore $1" >> "$TEST_LOG"; }
clauddy_stop_daemon() { echo stop >> "$TEST_LOG"; }
clauddy_start_daemon() { echo connected >> "$TEST_LOG"; }
clauddy_lock_acquire_or_die() { mkdir "$HOME/lock"; }
clauddy_lock_release() { rmdir "$HOME/lock" 2>/dev/null || true; }
''')
        scripts = {
            clauddy / 'clauddy': 'echo "$*" >> "$TEST_LOG"',
            bindir / 'dv': 'echo "$*" >> "$TEST_LOG"',
            bindir / 'osascript': 'echo "$*" >> "$TEST_LOG"',
            bindir / 'SwitchAudioSource': ':',
            bindir / 'sleep': '/bin/sleep "${TEST_TICK:-0.001}"',
        }
        for path, body in scripts.items():
            path.write_text('#!/bin/bash\n' + body + '\n')
            path.chmod(0o755)
        self.env = dict(os.environ, HOME=str(self.home), TEST_LOG=str(self.log),
                        TEST_BIN=str(bindir), PATH=str(bindir) + ':' + os.environ['PATH'])

    def run_timer(self, *args):
        result = subprocess.run(['bash', str(self.script), *args], env=self.env,
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.home / 'lock').exists())
        self.assertIn('resume', self.log.read_text().splitlines())
        return result.stdout, self.log.read_text()

    def test_music_starts_after_connection_and_is_restored(self):
        output, events = self.run_timer('--test-seconds', '8')
        self.assertLess(events.index('connected'), events.index('to play'))
        self.assertIn('to pause', events)
        self.assertIn('restore speakers', events)
        self.assertIn('raw 72 03 01 00 08', events)
        self.assertNotIn('raw 72 03 01 00 00', events)
        self.assertIn('Pomodoro session complete.', output)

    def test_two_work_break_cycles_include_final_break(self):
        output, events = self.run_timer('1', '1', '2', '--no-music')
        phases = [line for line in output.splitlines() if line.startswith(('Work', 'Break'))]
        self.assertEqual(phases, ['Work 1/2: 60s', 'Break 1/2: 60s',
                                  'Work 2/2: 60s', 'Break 2/2: 60s'])
        self.assertNotIn('to play', events)
        self.assertNotIn('to pause', events)
        self.assertIn('raw 72 03 00 00 00', events)

    def test_termination_stops_timer_and_releases_lock(self):
        self.env['TEST_TICK'] = '0.05'
        process = subprocess.Popen(['bash', str(self.script), '--test-seconds', '20', '--no-music'],
                                   env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            deadline = time.monotonic() + 3
            while 'raw 72 03 01' not in self.log.read_text() and time.monotonic() < deadline:
                time.sleep(.01)
            self.assertIn('raw 72 03 01', self.log.read_text())
            process.terminate()
            process.communicate(timeout=3)
            self.assertEqual(process.returncode, 143)
            self.assertFalse((self.home / 'lock').exists())
            self.assertIn('resume', self.log.read_text().splitlines())
            self.assertIn('raw 72 03 00 00 00', self.log.read_text())
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()
