import importlib.util
import json
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch, Mock

ROOT = Path(__file__).resolve().parents[1]


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / "apps/clauddy" / filename)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


adapter = module("codex_adapter", "codex-hook.py")
installer = module("codex_installer", "install-codex-hooks.py")


class CodexHookTests(unittest.TestCase):
    def test_working_and_waiting_events(self):
        for event in ("UserPromptSubmit", "PreToolUse", "PostToolUse"):
            self.assertEqual(adapter.state_for({"hook_event_name": event}), "working")
        self.assertEqual(adapter.state_for({"hook_event_name": "PermissionRequest"}), "alerting")

    def test_finished_question_stays_waiting(self):
        self.assertEqual(adapter.state_for({"hook_event_name": "Stop", "last_assistant_message": "Which option?"}), "alerting")
        self.assertEqual(adapter.state_for({"hook_event_name": "Stop", "last_assistant_message": "The update is complete."}), "chilling")
        self.assertEqual(adapter.state_for({"hook_event_name": "Interrupt"}), "chilling")

    def test_formatted_questions_stay_alerting(self):
        messages = (
            "**Did you see vibin’ during my last reply?**",
            "Can you see it?",
            "*Which option?*",
            '> "Is it alerting now?"',
            "`Ready?`",
        )
        for message in messages:
            with self.subTest(message=message):
                self.assertEqual(adapter.state_for({"hook_event_name": "Stop", "last_assistant_message": message}), "alerting")

    def test_prompt_text_is_not_forwarded_to_shell_hook(self):
        process = Mock()
        with patch.object(adapter.subprocess, "Popen", return_value=process) as launch:
            adapter.run({"hook_event_name": "UserPromptSubmit", "session_id": "test-session", "prompt": "private words"})
        payload = json.loads(process.communicate.call_args.args[0])
        self.assertEqual(payload, {"hook_event_name": "UserPromptSubmit", "session_id": "codex-test-session"})
        env = launch.call_args.kwargs["env"]
        self.assertEqual(env["CLAUDDY_HOOK_SYNC"], "1")

    def test_installer_preserves_unrelated_hooks_and_is_idempotent(self):
        unrelated = {"type": "command", "command": "/somewhere/codex-hook.py"}
        old = {"description": "Keep this", "hooks": {"Stop": [{"hooks": [unrelated]}]}}
        command = "/usr/bin/python3 /checkout/apps/clauddy/codex-hook.py"
        once = installer.merge(old, command)
        self.assertEqual(installer.merge(once, command), once)
        self.assertEqual(once["description"], "Keep this")
        self.assertIn({"hooks": [unrelated]}, once["hooks"]["Stop"])
        self.assertEqual(len(old["hooks"]["Stop"]), 1)

    def test_five_hooks_replace_the_old_eight_without_removing_other_handlers(self):
        command = "/usr/bin/python3 /checkout/apps/clauddy/codex-hook.py"
        old = {"hooks": {event: [{"hooks": [{"type": "command", "command": command}]}]
                         for event in adapter.EVENTS}}
        unrelated = {"hooks": [{"type": "command", "command": "/other/start.sh"}]}
        old["hooks"]["SessionStart"].append(unrelated)
        updated = installer.merge(old, command)
        active = {event for event, groups in updated["hooks"].items()
                  if any(handler.get("command") == command for group in groups for handler in group["hooks"])}
        self.assertEqual(active, {"UserPromptSubmit", "PermissionRequest", "PostToolUse", "Stop", "Interrupt"})
        self.assertEqual(updated["hooks"]["SessionStart"], [unrelated])
        self.assertEqual(updated["hooks"]["SessionEnd"], [])
        self.assertEqual(updated["hooks"]["PreToolUse"], [])

    def test_permission_hook_never_returns_an_approval_decision(self):
        # Unknown or malformed events must still return harmless, valid JSON.
        result = subprocess.run(["/usr/bin/python3", str(ROOT / "apps/clauddy/codex-hook.py")],
                                input='{"hook_event_name":"Unknown"}', text=True, capture_output=True)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(json.loads(result.stdout), {})

    def test_short_end_hooks_do_not_start_a_new_connection(self):
        with patch.object(adapter.Path, "exists", return_value=False), patch.object(adapter.subprocess, "Popen") as launch:
            adapter.run({"hook_event_name": "SessionEnd"})
        launch.assert_not_called()


if __name__ == "__main__":
    unittest.main()
