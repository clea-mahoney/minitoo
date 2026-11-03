#!/usr/bin/env python3
"""Translate Codex lifecycle events into Clauddy faces without changing approval decisions."""
import argparse
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
EVENTS = ("SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest",
          "PostToolUse", "Stop", "Interrupt", "SessionEnd")


def state_for(payload):
    event = payload.get("hook_event_name")
    if event in ("UserPromptSubmit", "PreToolUse", "PostToolUse"):
        return "working"
    if event == "PermissionRequest":
        return "alerting"
    if event == "Stop":
        message = (payload.get("last_assistant_message") or "").strip().lower()
        # Ignore closing Markdown emphasis and quotation marks.
        question_ending = message.rstrip(' \t\r\n*_`~"\'”’)]}')
        requests = ("let me know", "should i", "shall i", "want me to", "can you confirm",
                    "please confirm", "your call", "your decision", "give the word", "say the word")
        return "alerting" if question_ending.endswith("?") or any(p in message for p in requests) else "chilling"
    if event in ("SessionStart", "SessionEnd", "Interrupt"):
        return "chilling"
    return None


def hook_environment(config):
    env = dict(os.environ)
    env["PATH"] = os.pathsep.join([str(Path.home() / ".local/bin"), "/opt/homebrew/bin",
                                   "/usr/local/bin", env.get("PATH", "/usr/bin:/bin")])
    if config.get("core_dir"):
        env["CLAUDDY_CORE_DIR"] = config["core_dir"]
    env["CLAUDDY_HOOK_SYNC"] = "1"
    # Terminal events cannot rely on a detached sleep-and-retry process.
    env["CLAUDDY_WORK_HOLD"] = "0"
    env["CLAUDDY_ALERT_HOLD"] = "0"
    return env


def run(payload, config=None):
    state = state_for(payload)
    if state is None:
        return None
    config = config or {}
    event = payload["hook_event_name"]
    env = hook_environment(config)
    # Ending a chat should never start a new Bluetooth connection.
    if event in ("SessionEnd", "Interrupt") and not Path(env.get("DIVOOM_FIFO", "/tmp/divoom.fifo")).exists():
        return state
    session = str(payload.get("session_id") or "")
    if re.fullmatch(r"[A-Za-z0-9-]+", session):
        session = "codex-" + session
    else:
        session = ""
    safe_payload = {"session_id": session, "hook_event_name": event}
    # Prompt and assistant text are used only for classification, never logged or forwarded.
    process = subprocess.Popen(["/bin/bash", str(HERE / "clauddy-hook.sh"), state],
        stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        env=env, start_new_session=True)
    try:
        process.communicate(json.dumps(safe_payload).encode(), timeout=2.4 if event in ("SessionEnd", "Interrupt") else 10)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.communicate(timeout=.2)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.communicate()
    return state


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    try:
        payload = json.load(sys.stdin)
        if not isinstance(payload, dict):
            raise ValueError("Expected a hook object")
        if args.dry_run:
            print(json.dumps({"state": state_for(payload)}))
            return
        config_path = Path.home() / ".clauddy/codex-config.json"
        config = json.loads(config_path.read_text()) if config_path.exists() else {}
        run(payload, config)
    except Exception:
        # A desk-display failure must never interrupt work or decide an approval.
        pass
    print("{}")


if __name__ == "__main__":
    main()
