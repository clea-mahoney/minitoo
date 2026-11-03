#!/usr/bin/env python3
"""Render colored messages and stream them through the persistent Bluetooth helper."""
import http.server
import json
import os
import sys
import threading
import time
import urllib.parse
import re
import tempfile
import signal
from pathlib import Path

import media_sender

from PIL import Image, ImageDraw, ImageFont

WIDTH, HEIGHT = 160, 128
DEBOUNCE_MS = 200
STATE_LOCK = threading.Lock()
PENDING = {"runs": [], "name": "", "seq": 0}
RESULTS = {}
STOP = threading.Event()
RUNTIME = tempfile.TemporaryDirectory(prefix="minitoo-studio-")
TMP_IMG = str(Path(RUNTIME.name) / "frame.png")

EMOJI_FONT_PATH = "/System/Library/Fonts/Apple Symbols.ttf"

APPLE_EMOJI_FONT_PATH = "/System/Library/Fonts/Apple Color Emoji.ttc"
APPLE_EMOJI_STRIKE = 160

def _is_emoji(ch: str) -> bool:
    cp = ord(ch)
    return (
        0x1F000 <= cp <= 0x1FFFF  # emoticons, pictographs, transport, supplemental symbols
        or 0x2600 <= cp <= 0x27BF  # misc symbols, dingbats
        or 0x2B00 <= cp <= 0x2BFF  # misc symbols and arrows (stars, etc.)
        or cp in (0x2764, 0x2660, 0x2663, 0x2665, 0x2666)  # heart/suit symbols outside the main blocks
        or cp in (0xFE0F, 0x200D)  # variation selector-16, zero-width joiner
    )

def _is_emoji_only(s: str) -> bool:
    stripped = "".join(s.split())
    return bool(stripped) and all(_is_emoji(c) for c in stripped)

def _font_for(ch: str, text_font, emoji_font):
    return emoji_font if _is_emoji(ch) else text_font

def _segments(s: str, text_font, emoji_font):
    pass
    if not s:
        return
    cur_font = _font_for(s[0], text_font, emoji_font)
    cur = s[0]
    for ch in s[1:]:
        f = _font_for(ch, text_font, emoji_font)
        if f is cur_font:
            cur += ch
        else:
            yield cur, cur_font
            cur, cur_font = ch, f
    yield cur, cur_font

def _measure(draw, s: str, text_font, emoji_font) -> float:
    return sum(draw.textlength(seg, font=f) for seg, f in _segments(s, text_font, emoji_font))

def _draw_line(draw, x, y, s: str, text_font, emoji_font, color, emoji_is_color: bool) -> None:
    for seg, f in _segments(s, text_font, emoji_font):
        if f is emoji_font and emoji_is_color:
            draw.text((x, y), seg, font=f, embedded_color=True)
        else:
            draw.text((x, y), seg, fill=color, font=f)
        x += draw.textlength(seg, font=f)

def _tokenize_words(chars: list[tuple[str, str]]) -> list[list[tuple[str, str]]]:
    pass
    words: list[list[tuple[str, str]]] = []
    cur: list[tuple[str, str]] = []
    for ch, color in chars:
        if ch.isspace():
            if cur:
                words.append(cur)
                cur = []
        else:
            cur.append((ch, color))
    if cur:
        words.append(cur)
    return words

def _break_wide_words(words, max_w, draw, text_font, emoji_font):
    pass
    out: list[list[tuple[str, str]]] = []
    for word in words:
        if _measure_chars(draw, word, text_font, emoji_font) <= max_w:
            out.append(word)
            continue
        chunk: list[tuple[str, str]] = []
        for ch in word:
            trial = chunk + [ch]
            if chunk and _measure_chars(draw, trial, text_font, emoji_font) > max_w:
                out.append(chunk)
                chunk = [ch]
            else:
                chunk = trial
        if chunk:
            out.append(chunk)
    return out

def _line_chars(words: list[list[tuple[str, str]]]) -> list[tuple[str, str]]:
    out: list[tuple[str, str]] = []
    for i, word in enumerate(words):
        if i > 0:
            out.append((" ", "#FFFFFF"))  # space is invisible; color is never drawn
        out.extend(word)
    return out

def _segments_colored(chars: list[tuple[str, str]], text_font, emoji_font):
    pass
    if not chars:
        return
    cur_font = _font_for(chars[0][0], text_font, emoji_font)
    cur_color = chars[0][1]
    cur_text = chars[0][0]
    for ch, color in chars[1:]:
        f = _font_for(ch, text_font, emoji_font)
        same_run = f is cur_font and (f is emoji_font or color == cur_color)
        if same_run:
            cur_text += ch
        else:
            yield cur_text, cur_font, cur_color
            cur_font, cur_color, cur_text = f, color, ch
    yield cur_text, cur_font, cur_color

def _measure_chars(draw, chars: list[tuple[str, str]], text_font, emoji_font) -> float:
    return sum(draw.textlength(seg, font=f) for seg, f, _ in _segments_colored(chars, text_font, emoji_font))

def _draw_line_colored(draw, x, y, chars: list[tuple[str, str]], text_font, emoji_font, emoji_is_color: bool) -> None:
    for seg, f, color in _segments_colored(chars, text_font, emoji_font):
        if f is emoji_font and emoji_is_color:
            draw.text((x, y), seg, font=f, embedded_color=True)
        else:
            draw.text((x, y), seg, fill=color, font=f)
        x += draw.textlength(seg, font=f)

def _render_emoji_only(text: str) -> Image.Image:
    stripped = "".join(text.split())
    margin = 14
    max_w, max_h = WIDTH - 2 * margin, HEIGHT - 2 * margin

    try:
        color_font = ImageFont.truetype(APPLE_EMOJI_FONT_PATH, APPLE_EMOJI_STRIKE)
        measure_draw = ImageDraw.Draw(Image.new("RGBA", (1, 1)))
        text_w = measure_draw.textlength(stripped, font=color_font)
        pad = APPLE_EMOJI_STRIKE
        scratch = Image.new("RGBA", (int(text_w) + pad * 2, APPLE_EMOJI_STRIKE + pad * 2), (0, 0, 0, 0))
        scratch_draw = ImageDraw.Draw(scratch)
        scratch_draw.text((pad, pad), stripped, font=color_font, embedded_color=True)
        bbox = scratch.getbbox()
        if not bbox:
            raise ValueError("empty glyph bbox")
        glyph = scratch.crop(bbox)
        scale = min(max_w / glyph.width, max_h / glyph.height)
        new_w, new_h = max(1, int(glyph.width * scale)), max(1, int(glyph.height * scale))
        glyph = glyph.resize((new_w, new_h), Image.LANCZOS)
        img = Image.new("RGB", (WIDTH, HEIGHT), "black")
        img.paste(glyph, ((WIDTH - new_w) // 2, (HEIGHT - new_h) // 2), glyph)
        return img
    except Exception as e:
        print(f"color emoji render failed, falling back to outline: {e}", file=sys.stderr)
        img = Image.new("RGB", (WIDTH, HEIGHT), "black")
        draw = ImageDraw.Draw(img)
        try:
            big_emoji_font = ImageFont.truetype(EMOJI_FONT_PATH, 64)
        except OSError:
            big_emoji_font = ImageFont.load_default()
        w = draw.textlength(stripped, font=big_emoji_font)
        bbox = draw.textbbox((0, 0), stripped, font=big_emoji_font)
        h = bbox[3] - bbox[1]
        x = max(margin, (WIDTH - w) // 2)
        y = max(margin, (HEIGHT - h) // 2) - bbox[1]
        draw.text((x, y), stripped, fill="#FFFFFF", font=big_emoji_font)
        return img

def render(runs: list[dict], name: str = "") -> str:
    pass
    runs = [{**r, "text": "".join(c for c in r.get("text", "") if not 0x1F3FB <= ord(c) <= 0x1F3FF)} for r in runs]
    full_text = "".join(r.get("text", "") for r in runs)
    if _is_emoji_only(full_text):
        img = _render_emoji_only(full_text)
        img.save(TMP_IMG)
        return TMP_IMG

    chars: list[tuple[str, str]] = []
    for r in runs:
        run_color = r.get("color") or "#FFFFFF"
        for ch in r.get("text", ""):
            chars.append((ch, run_color))

    img = Image.new("RGB", (WIDTH, HEIGHT), color="black")
    draw = ImageDraw.Draw(img)
    try:
        text_font = ImageFont.truetype("/System/Library/Fonts/Menlo.ttc", 18)
    except OSError:
        text_font = ImageFont.load_default()
    emoji_is_color = False
    try:
        emoji_font = ImageFont.truetype(APPLE_EMOJI_FONT_PATH, 20)
        emoji_is_color = True
    except OSError:
        try:
            emoji_font = ImageFont.truetype(EMOJI_FONT_PATH, 20)
        except OSError:
            emoji_font = text_font  # bundled font missing -- falls back to tofu boxes, not a crash

    MARGIN = 14
    words = _tokenize_words(chars)
    words = _break_wide_words(words, WIDTH - 2 * MARGIN, draw, text_font, emoji_font)
    lines, cur_words, cur_text = [], [], ""
    for word in words:
        word_text = "".join(ch for ch, _ in word)
        trial = (cur_text + " " + word_text).strip()
        if _measure(draw, trial, text_font, emoji_font) > WIDTH - 2 * MARGIN and cur_words:
            lines.append(cur_words)
            cur_words, cur_text = [word], word_text
        else:
            cur_words.append(word)
            cur_text = trial
    if cur_words:
        lines.append(cur_words)
    if not lines:
        lines = [[]]

    line_h = 22
    VMARGIN = 4
    max_lines = max(1, (HEIGHT - 2 * VMARGIN) // line_h)
    if len(lines) > max_lines:
        lines = lines[:max_lines]
        last_words = lines[-1]
        ellipsis_color = last_words[-1][-1][1] if last_words and last_words[-1] else "#FFFFFF"
        while last_words:
            trial_chars = _line_chars(last_words) + [("…", ellipsis_color)]
            if _measure_chars(draw, trial_chars, text_font, emoji_font) <= WIDTH - 2 * MARGIN:
                break
            last_words[-1].pop()
            if not last_words[-1]:
                last_words.pop()
        if last_words:
            ellipsis_color = last_words[-1][-1][1]
            last_words[-1] = last_words[-1] + [("…", ellipsis_color)]
        else:
            last_words = [[("…", ellipsis_color)]]
        lines[-1] = last_words

    total_h = line_h * len(lines)
    y = max(VMARGIN, (HEIGHT - total_h) // 2)
    for line_words in lines:
        line_chars = _line_chars(line_words)
        w = _measure_chars(draw, line_chars, text_font, emoji_font)
        x = max(MARGIN, (WIDTH - w) // 2)
        _draw_line_colored(draw, x, y, line_chars, text_font, emoji_font, emoji_is_color)
        y += line_h

    img.save(TMP_IMG)
    return TMP_IMG

def push_worker():
    last_seq_sent = 0
    while not STOP.is_set():
        time.sleep(DEBOUNCE_MS / 1000)
        with STATE_LOCK:
            seq, runs, name = PENDING["seq"], PENDING["runs"], PENDING["name"]
        if seq == last_seq_sent:
            continue
        time.sleep(DEBOUNCE_MS / 1000)
        with STATE_LOCK:
            if PENDING["seq"] != seq or STOP.is_set():
                continue
            RESULTS[seq] = {"state": "sending"}
        last_seq_sent = seq
        try:
            path = render(runs, name)
            receipt = media_sender.push(path)
            result = {"state": "acknowledged", **receipt}
        except Exception as error:
            result = {"state": "failed", "error": str(error)}
            print(f"transfer failed: {error}", file=sys.stderr)
        with STATE_LOCK:
            RESULTS[seq] = result


def validate_message(data):
    if not isinstance(data, dict):
        raise ValueError("Expected a JSON object")
    runs = data.get("runs")
    if runs is None:
        runs = [{"text": data.get("text", ""), "color": data.get("color", "#E2F6EF")}]
    if not isinstance(runs, list) or len(runs) > 300:
        raise ValueError("Invalid color runs")
    clean = []
    for run in runs:
        if not isinstance(run, dict) or not isinstance(run.get("text"), str):
            raise ValueError("Each color run needs text")
        color = run.get("color", "#E2F6EF")
        if not isinstance(color, str) or not re.fullmatch(r"#[0-9a-fA-F]{6}", color):
            raise ValueError("Use a six-digit hex color")
        clean.append({"text": run["text"], "color": color})
    if sum(len(run["text"]) for run in clean) > 300:
        raise ValueError("Messages are limited to 300 characters")
    name = data.get("name", "")
    if not isinstance(name, str) or len(name) > 40:
        raise ValueError("Invalid sender name")
    return clean, name


class Handler(http.server.BaseHTTPRequestHandler):
    def _send(self, code, body, ctype="application/json"):
        if not isinstance(body, bytes):
            body = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path in ("/", "/index.html"):
            self._send(200, Path(__file__).with_name("index.html").read_bytes(), "text/html")
        elif self.path == "/health":
            self._send(200, {"ok": True})
        elif re.fullmatch(r"/delivery/\d+", self.path):
            with STATE_LOCK:
                result = RESULTS.get(int(self.path.rsplit("/", 1)[1]))
            self._send(200 if result is not None else 404, result or {"error": "Unknown update"})
        else:
            self._send(404, {"error": "Not found"})

    def do_POST(self):
        if self.path != "/update":
            self._send(404, {"error": "Not found"})
            return
        host = self.headers.get("Host", "")
        origin = self.headers.get("Origin")
        if host not in (f"127.0.0.1:{self.server.server_port}", f"localhost:{self.server.server_port}"):
            self._send(403, {"error": "Local requests only"})
            return
        if origin and origin != "http://" + host:
            self._send(403, {"error": "Local requests only"})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if not 0 < length <= 16384:
                raise ValueError("Invalid request size")
            if self.headers.get_content_type() != "application/json":
                raise ValueError("Send application/json")
            runs, name = validate_message(json.loads(self.rfile.read(length)))
        except (ValueError, UnicodeDecodeError) as error:
            self._send(400, {"error": str(error)})
            return
        with STATE_LOCK:
            previous = PENDING["seq"]
            if RESULTS.get(previous, {}).get("state") == "queued":
                RESULTS[previous] = {"state": "superseded"}
            PENDING.update(runs=runs, name=name, seq=previous + 1)
            seq = PENDING["seq"]
            RESULTS[seq] = {"state": "queued"}
            for old in sorted(RESULTS)[:-100]:
                del RESULTS[old]
        self._send(202, {"ok": True, "seq": seq})

    def log_message(self, fmt, *args):
        pass


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
    worker = threading.Thread(target=push_worker, daemon=True)
    httpd = http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler)
    def shutdown(_signum, _frame):
        STOP.set()
        threading.Thread(target=httpd.shutdown, daemon=True).start()
    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)
    worker.start()
    print(f"live-studio listening on http://127.0.0.1:{port}")
    try:
        httpd.serve_forever()
    finally:
        STOP.set()
        httpd.server_close()
        worker.join()

if __name__ == "__main__":
    main()
