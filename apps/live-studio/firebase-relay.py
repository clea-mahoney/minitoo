#!/usr/bin/env python3
"""Relay authorized remote messages and report the actual media-transfer result."""
import json
import os
from pathlib import Path
import sys
import time
import urllib.request

from cloud import Firebase, request

DATA_DIR = Path(os.environ.get("LIVE_STUDIO_DATA_DIR", Path.home() / ".clauddy" / "live-studio"))
LOG_FILE = DATA_DIR / "messages.jsonl"
LOCAL = os.environ.get("LOCAL_UPDATE_URL", "http://127.0.0.1:8765/update")
MESSAGE_PATH = "minitoo-live"
STATUS_PATH = "minitoo-status"


def log_message(data, receipt):
    DATA_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
    # Logging stays on this computer. No messages are written into the source tree.
    entry = {"ts": data["ts"], "name": data.get("name", ""), "runs": data.get("runs"),
             "text": data.get("text", ""), "result": receipt}
    with LOG_FILE.open("a", encoding="utf-8") as stream:
        stream.write(json.dumps(entry, ensure_ascii=False) + "\n")
    LOG_FILE.chmod(0o600)


def push_local(data):
    return request(LOCAL, {"runs": data.get("runs"), "text": data.get("text", ""),
                           "color": data.get("color", "#E2F6EF"), "name": data.get("name", "")}, "POST")["seq"]


def local_result(seq):
    return request(LOCAL.rsplit("/", 1)[0] + f"/delivery/{seq}")


def main():
    cloud = Firebase()
    last_ts = None
    have_snapshot = False
    pending = None
    while True:
        try:
            # Heartbeats continue while the worker is transferring a message.
            request(LOCAL.rsplit("/", 1)[0] + "/health")
            status = {"heartbeat": int(time.time() * 1000), "backend_off": False}
            if pending:
                message, seq = pending
                result = local_result(seq)
                if result["state"] in ("acknowledged", "failed", "superseded"):
                    status["last_result"] = {"for_ts": message["ts"],
                        "ok": result["state"] == "acknowledged", "error": result.get("error", result["state"]),
                        "ts": int(time.time() * 1000)}
                    log_message(message, result)
                    pending = None
            if pending is None:
                data = cloud.call(MESSAGE_PATH)
                if not have_snapshot:
                    # The current cloud value can be weeks old. Start with new sends only.
                    last_ts = data.get("ts") if isinstance(data, dict) else None
                    have_snapshot = True
                elif isinstance(data, dict) and data.get("ts") is not None and data["ts"] != last_ts:
                    seq = push_local(data)
                    last_ts = data["ts"]
                    pending = data, seq
            cloud.call(STATUS_PATH, status, "PATCH")
        except Exception as error:
            # Do not print URLs or exception payloads containing authentication tokens.
            print(f"Remote relay could not complete a request ({type(error).__name__}). Check local configuration and Firebase rules.", file=sys.stderr)
        time.sleep(1)


if __name__ == "__main__":
    main()
