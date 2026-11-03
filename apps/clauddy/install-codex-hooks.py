#!/usr/bin/env python3
"""Install Clauddy's Codex hooks, preserving unrelated hooks and requiring Codex trust review."""
import argparse
from datetime import datetime
import json
import os
from pathlib import Path
import shlex
import shutil
import tempfile

EVENTS = ("UserPromptSubmit", "PermissionRequest", "PostToolUse", "Stop", "Interrupt")


def merge(existing, command):
    result = json.loads(json.dumps(existing))
    hooks = result.setdefault("hooks", {})
    for event, groups in list(hooks.items()):
        kept = []
        for group in groups:
            group = dict(group)
            group["hooks"] = [handler for handler in group.get("hooks", [])
                              if "/apps/clauddy/codex-hook.py" not in handler.get("command", "")]
            if group["hooks"]:
                kept.append(group)
        hooks[event] = kept
    for event in EVENTS:
        hooks.setdefault(event, []).append({"hooks": [{"type": "command", "command": command,
            "timeout": 3 if event in ("SessionEnd", "Interrupt") else 12,
            "statusMessage": "Updating Clauddy"}]})
    return result


def write_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", dir=path.parent, delete=False) as stream:
        json.dump(data, stream, indent=2)
        stream.write("\n")
        temporary = Path(stream.name)
    temporary.chmod(0o600)
    temporary.replace(path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--core-dir", type=Path, help="Reuse an existing approved Bluetooth helper")
    parser.add_argument("--remove", action="store_true", help="Remove only Clauddy's Codex hooks")
    args = parser.parse_args()
    codex_home = Path(os.environ.get("CODEX_HOME", Path.home() / ".codex"))
    target = codex_home / "hooks.json"
    existing = json.loads(target.read_text()) if target.exists() else {}
    script = Path(__file__).with_name("codex-hook.py").resolve()
    command = "/usr/bin/python3 " + shlex.quote(str(script))
    updated = merge(existing, command)
    if args.remove:
        for groups in updated["hooks"].values():
            groups[:] = [group for group in groups if not any(
                handler.get("command") == command for handler in group["hooks"])]
    if target.exists():
        backup = target.with_name("hooks.json.backup-" + datetime.now().strftime("%Y%m%d-%H%M%S-%f"))
        shutil.copy2(target, backup)
    if args.core_dir:
        core = args.core_dir.expanduser().resolve()
        if not (core / "divoom-send.app").is_dir():
            parser.error("The existing core directory must contain divoom-send.app")
        write_json(Path.home() / ".clauddy/codex-config.json", {"core_dir": str(core)})
    write_json(target, updated)
    print("Clauddy hooks removed." if args.remove else "Clauddy hooks installed. In Codex, open Settings > Hooks and review/trust the Clauddy hooks.")


if __name__ == "__main__":
    main()
