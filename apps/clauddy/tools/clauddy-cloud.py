#!/usr/bin/env python3

from __future__ import annotations

import argparse
import getpass
import hashlib
import json
import locale
import os
import shlex
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any

DEFAULT_BASE_URL = "https://appin.divoom-gz.com"
STYLE_RIMLESS = 798
STYLE_NOISE_BARS = 828
STYLE_FRAME_13 = 805
STYLE_FRAME_12 = 804

class DivoomError(RuntimeError):
    pass

@dataclass
class Auth:
    user_id: int
    token: int

def java_md5(text: str) -> str:
    data = bytes(ord(ch) & 0xFF for ch in text)
    return hashlib.md5(data).hexdigest()

def default_timezone() -> str:
    hours = -time.timezone // 3600
    return f"+{hours}" if hours >= 0 else str(hours)

def default_country() -> str:
    loc = locale.getlocale()[0] or ""
    if "_" in loc:
        return loc.split("_", 1)[1].upper()
    return "US"

def default_language() -> str:
    loc = locale.getlocale()[0] or ""
    lang = loc.split("_", 1)[0].lower() if loc else "en"
    if lang == "zh":
        return "zh-hans" if default_country() in {"CN", "SG"} else "zh-hant"
    return lang or "en"

def post_json(base_url: str, command: str, payload: dict[str, Any], timeout: float) -> dict[str, Any]:
    url = f"{base_url.rstrip('/')}/{command}"
    body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=body,
        headers={
            "Content-Type": "application/json; charset=utf-8",
            "Connection": "close",
            "User-Agent": "clauddy-setup/1",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8", errors="replace")
        raise DivoomError(f"{command}: HTTP {exc.code}: {raw}") from exc
    except urllib.error.URLError as exc:
        raise DivoomError(f"{command}: network error: {exc.reason}") from exc

    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise DivoomError(f"{command}: non-JSON response: {raw[:500]}") from exc

    code = parsed.get("ReturnCode")
    if code not in (0, None):
        raise DivoomError(f"{command}: ReturnCode={code} ReturnMessage={parsed.get('ReturnMessage')!r}")
    return parsed

def base_payload(args: argparse.Namespace, auth: Auth | None = None) -> dict[str, Any]:
    return {
        "DeviceId": args.device_id,
        "Token": auth.token if auth else 0,
        "UserId": auth.user_id if auth else 0,
    }

def login(args: argparse.Namespace, email: str, password: str) -> Auth:
    response = post_json(
        args.base_url,
        "UserLogin",
        {
            **base_payload(args),
            "Command": "UserLogin",
            "Email": email,
            "Password": java_md5(password),
            "TimeZone": args.timezone,
            "CountryISOCode": args.country,
            "Language": args.language,
        },
        args.timeout,
    )
    user_id = int(response.get("UserId") or 0)
    token = int(response.get("Token") or 0)
    if not user_id or not token:
        raise DivoomError("UserLogin succeeded but did not return UserId and Token")
    return Auth(user_id=user_id, token=token)

def my_clock_list(args: argparse.Namespace, auth: Auth) -> list[dict[str, Any]]:
    response = post_json(
        args.base_url,
        "Channel/MyClockGetList",
        {
            **base_payload(args, auth),
            "Command": "Channel/MyClockGetList",
            "StartNum": 1,
            "EndNum": 100,
            "Flag": 0,
            "CountryISOCode": args.country,
            "Language": args.language,
        },
        args.timeout,
    )
    return list(response.get("ClockList") or [])

def store_custom_candidates(args: argparse.Namespace, auth: Auth) -> list[dict[str, Any]]:
    classify = post_json(
        args.base_url,
        "Channel/StoreClockGetClassify",
        {
            **base_payload(args, auth),
            "Command": "Channel/StoreClockGetClassify",
            "StartNum": 0,
            "EndNum": 0,
            "CountryISOCode": args.country,
            "Language": args.language,
        },
        args.timeout,
    )
    classify_list = list(classify.get("ClassifyList") or [])
    if not classify_list:
        return []
    classify_id = int(classify_list[0].get("ClassifyId") or 0)
    response = post_json(
        args.base_url,
        "Channel/StoreClockGetList",
        {
            **base_payload(args, auth),
            "Command": "Channel/StoreClockGetList",
            "StartNum": 1,
            "EndNum": 30,
            "Flag": 0,
            "ClassifyId": classify_id,
            "CountryISOCode": args.country,
            "Language": args.language,
        },
        args.timeout,
    )
    return list(response.get("ClockList") or [])

def map_custom_clocks(items: list[dict[str, Any]]) -> dict[str, int]:
    found: dict[str, int] = {}
    by_type = {3: "chilling", 4: "working", 5: "alerting"}
    for item in items:
        try:
            clock_type = int(item.get("ClockType") or 0)
            clock_id = int(item.get("ClockId") or 0)
        except (TypeError, ValueError):
            continue
        state = by_type.get(clock_type)
        if state and clock_id:
            found[state] = clock_id
    return found

def set_style(args: argparse.Namespace, auth: Auth, clock_id: int, style_id: int) -> None:
    post_json(
        args.base_url,
        "Channel/SetClockStyle",
        {
            **base_payload(args, auth),
            "Command": "Channel/SetClockStyle",
            "ClockId": clock_id,
            "StyleId": style_id,
            "ParentClockId": 0,
            "ParentItemId": "",
            "PageIndex": 0,
            "LcdIndependence": 0,
            "LcdIndex": 0,
            "Language": args.language,
        },
        args.timeout,
    )

MANAGED_KEYS = {
    "CLAUDDY_MINITOO_MAC",
    "CLAUDDY_DEVICE_ID",
    "CLAUDDY_CLOCK_CHILLING",
    "CLAUDDY_CLOCK_WORKING",
    "CLAUDDY_CLOCK_ALERTING",
    "CLAUDDY_PAGE_CHILLING",
    "CLAUDDY_PAGE_WORKING",
    "CLAUDDY_PAGE_ALERTING",
    "CLAUDDY_STYLE_CHILLING",
    "CLAUDDY_STYLE_WORKING",
    "CLAUDDY_STYLE_ALERTING",
    "CLAUDDY_GENERATED_AT",
}

def read_existing_config(path: Path) -> dict[str, str]:
    pass
    if not path.exists():
        return {}
    found: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip()
        if key and key not in MANAGED_KEYS:
            found[key] = value.strip()
    return found

def shell_config(args: argparse.Namespace, clocks: dict[str, int]) -> str:
    values = {
        "CLAUDDY_MINITOO_MAC": args.mac,
        "CLAUDDY_DEVICE_ID": str(args.device_id),
        "CLAUDDY_CLOCK_CHILLING": str(clocks["chilling"]),
        "CLAUDDY_CLOCK_WORKING": str(clocks["working"]),
        "CLAUDDY_CLOCK_ALERTING": str(clocks["alerting"]),
        "CLAUDDY_PAGE_CHILLING": "0",
        "CLAUDDY_PAGE_WORKING": "1",
        "CLAUDDY_PAGE_ALERTING": "2",
        "CLAUDDY_STYLE_CHILLING": str(STYLE_FRAME_13),
        "CLAUDDY_STYLE_WORKING": str(STYLE_NOISE_BARS),
        "CLAUDDY_STYLE_ALERTING": str(STYLE_FRAME_12),
        "CLAUDDY_GENERATED_AT": str(int(time.time())),
    }
    lines = [
        "# Clauddy local config.",
        "# Contains no Divoom password, auth token, or account secret.",
    ]
    for key, value in values.items():
        lines.append(f"{key}={shlex.quote(value)}")

    preserved = read_existing_config(args.config)
    if preserved:
        lines.append("")
        lines.append("# Preserved from the previous config (not managed by setup).")
        for key in sorted(preserved):
            lines.append(f"{key}={preserved[key]}")
    return "\n".join(lines) + "\n"

def cmd_setup(args: argparse.Namespace) -> int:
    email = args.email or input("Divoom email/username: ").strip()
    if not email:
        print("error: missing Divoom email/username", file=sys.stderr)
        return 2
    password = getpass.getpass("Divoom password (not stored): ")
    if not password:
        print("error: missing Divoom password", file=sys.stderr)
        return 2

    try:
        auth = login(args, email, password)
        clocks = map_custom_clocks(my_clock_list(args, auth))
        if set(clocks) != {"chilling", "working", "alerting"}:
            clocks.update({k: v for k, v in map_custom_clocks(store_custom_candidates(args, auth)).items() if k not in clocks})
        missing = {"chilling", "working", "alerting"} - set(clocks)
        if missing:
            raise DivoomError(f"could not find custom face IDs for: {', '.join(sorted(missing))}")

        set_style(args, auth, clocks["chilling"], STYLE_FRAME_13)
        set_style(args, auth, clocks["working"], STYLE_NOISE_BARS)
        set_style(args, auth, clocks["alerting"], STYLE_FRAME_12)
    except DivoomError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    args.config.parent.mkdir(parents=True, exist_ok=True)
    args.config.write_text(shell_config(args, clocks), encoding="utf-8")
    os.chmod(args.config, 0o600)

    print(f"logged in UserId={auth.user_id} Token=<hidden>")
    print(f"wrote {args.config}")
    print("custom faces:")
    print(f"  chilling -> ClockId={clocks['chilling']} StyleId={STYLE_FRAME_13}")
    print(f"  working  -> ClockId={clocks['working']} StyleId={STYLE_NOISE_BARS}")
    print(f"  alerting -> ClockId={clocks['alerting']} StyleId={STYLE_FRAME_12}")
    return 0

def clock_label(item: dict[str, Any]) -> str:
    for key in ("ClockName", "Name", "Title", "ClockTitle"):
        value = item.get(key)
        if value:
            return str(value)
    return "(unnamed)"

def device_id_from_config(path: Path) -> int:
    if not path.exists():
        return 0
    for line in path.read_text(encoding="utf-8").splitlines():
        key, _, value = line.strip().partition("=")
        if key.strip() == "CLAUDDY_DEVICE_ID":
            try:
                return int(value.strip().strip("'\""))
            except ValueError:
                return 0
    return 0

def cmd_list_clocks(args: argparse.Namespace) -> int:
    pass
    if args.device_id is None:
        args.device_id = device_id_from_config(args.config)

    email = args.email or input("Divoom email/username: ").strip()
    if not email:
        print("error: missing Divoom email/username", file=sys.stderr)
        return 2
    password = getpass.getpass("Divoom password (not stored): ")
    if not password:
        print("error: missing Divoom password", file=sys.stderr)
        return 2

    try:
        auth = login(args, email, password)
        items = my_clock_list(args, auth)
    except DivoomError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    if not items:
        print("My Clock list is empty. Add the face you want in the Divoom phone app first.")
        return 1

    custom_types = {3: "chilling (custom)", 4: "working (custom)", 5: "alerting (custom)"}
    print(f"My Clock list ({len(items)} entries):")
    print(f"  {'ClockId':>9}  {'Type':>4}  Name / role")
    for item in items:
        try:
            clock_id = int(item.get("ClockId") or 0)
            clock_type = int(item.get("ClockType") or 0)
        except (TypeError, ValueError):
            continue
        role = custom_types.get(clock_type, clock_label(item))
        print(f"  {clock_id:>9}  {clock_type:>4}  {role}")
    print()
    print("To make one of these the face Clauddy returns to when you stop working,")
    print("add its ClockId to your Clauddy config:")
    print(f"  echo 'CLAUDDY_CLOCK_DEFAULT=<ClockId>' >> {args.config}")
    print("then test it with:")
    print("  ./set-clauddy-state.sh default")
    return 0

def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Clauddy Divoom cloud setup.")
    sub = parser.add_subparsers(dest="cmd", required=True)

    setup = sub.add_parser("setup", help="Discover custom face IDs, set frame styles, and write local config.")
    setup.add_argument("--config", type=Path, required=True)
    setup.add_argument("--mac", required=True)
    setup.add_argument("--device-id", type=int, required=True)
    setup.add_argument("--email")
    setup.add_argument("--base-url", default=DEFAULT_BASE_URL)
    setup.add_argument("--country", default=default_country())
    setup.add_argument("--language", default=default_language())
    setup.add_argument("--timezone", default=default_timezone())
    setup.add_argument("--timeout", type=float, default=15.0)
    setup.set_defaults(func=cmd_setup)

    listing = sub.add_parser(
        "list-clocks",
        help="List every face in the account's My Clock list with its ClockId.",
    )
    listing.add_argument("--config", type=Path, default=Path.home() / ".clauddy" / "config")
    listing.add_argument("--device-id", type=int, default=None)
    listing.add_argument("--email")
    listing.add_argument("--base-url", default=DEFAULT_BASE_URL)
    listing.add_argument("--country", default=default_country())
    listing.add_argument("--language", default=default_language())
    listing.add_argument("--timezone", default=default_timezone())
    listing.add_argument("--timeout", type=float, default=15.0)
    listing.set_defaults(func=cmd_list_clocks)

    return parser.parse_args()

def main() -> int:
    args = parse_args()
    return args.func(args)

if __name__ == "__main__":
    raise SystemExit(main())
