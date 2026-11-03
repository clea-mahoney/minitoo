#!/usr/bin/env python3
"""Replay the previous or next message from this computer's private message log."""
import json
import os
from pathlib import Path
import sys
from cloud import Firebase


def main():
    if len(sys.argv) != 2 or sys.argv[1] not in ("back", "forward"):
        sys.exit("Usage: nav.py back|forward")
    folder = Path(os.environ.get("LIVE_STUDIO_DATA_DIR", Path.home() / ".clauddy" / "live-studio"))
    path = folder / "messages.jsonl"
    if not path.exists():
        sys.exit("No messages have been recorded on this computer.")
    entries = {}
    for line in path.read_text().splitlines():
        entry = json.loads(line)
        entries[entry["ts"]] = entry
    history = list(entries.values())
    cloud = Firebase()
    current = (cloud.call("minitoo-live") or {}).get("ts")
    index = next((i for i, entry in enumerate(history) if entry["ts"] == current), len(history) - 1)
    target = index + (-1 if sys.argv[1] == "back" else 1)
    if not 0 <= target < len(history):
        print("No more messages in that direction.")
        return
    entry = history[target]
    cloud.call("minitoo-live", {"text": entry["text"], "runs": entry.get("runs"),
                "color": (entry.get("runs") or [{"color": "#E2F6EF"}])[0]["color"],
                "name": entry["name"], "ts": entry["ts"]}, "PUT")
    print("Previous message queued." if sys.argv[1] == "back" else "Next message queued.")


if __name__ == "__main__":
    main()
