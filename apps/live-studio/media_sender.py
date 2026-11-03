"""Send one rendered frame, retaining the daemon and the character slots."""
import json
from pathlib import Path
import subprocess


def push(image_path):
    command = ["python3", str(Path(__file__).resolve().parents[2] / "core" / "media.py"), str(image_path)]
    import os
    if os.environ.get("LIVE_STUDIO_SIZE") == "128":
        command.append("--square")
    result = subprocess.run(command, capture_output=True, text=True, timeout=35)
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or "Bluetooth media transfer failed")
    return json.loads(result.stdout.strip().splitlines()[-1])
