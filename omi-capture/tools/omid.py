"""The capture daemon. One process, one status page.

Everything the host does runs here: receive uploads from the phone, transcribe,
drop the silence, write notes into the vault, expire old audio. Previously these
were separate scripts started by hand, which meant nothing survived a reboot and
there was no way to answer "is it working?" without reading a terminal.

    http://localhost:8723/         status page
    http://localhost:8723/health   what the phone probes
    POST /upload/<name>            what the phone uploads to

Install it to start at logon (no admin needed):

    python omid.py --install-task

Run:
    python omid.py
"""

from __future__ import annotations

import argparse
import html
import json
import os
import subprocess
import sys
import threading
import time
import traceback
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import process as proc
import read_segment
import transcribe as tx
import vault as vaultmod

# Windows consoles default to a legacy codepage (cp1252 here), and Parakeet v3
# is multilingual — one curly quote or one non-Latin character in a transcript
# and print() raises UnicodeEncodeError. That exception escaped the per-segment
# handler and aborted the whole pass, so a single unusual character stalled the
# entire queue. errors="replace" rather than strict: a mangled character in a
# log line is not worth stopping the pipeline for.
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, OSError):
        pass


class State:
    """Everything the status page needs. Written by the worker, read by HTTP."""

    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.started = datetime.now(timezone.utc)
        self.model_ready = False
        self.last_pass: datetime | None = None
        self.last_upload: datetime | None = None
        self.kept = 0
        self.dropped = 0
        self.notes = 0
        self.errors: list[str] = []
        self.recent: list[dict] = []

    def note_error(self, where: str, exc: BaseException) -> None:
        with self.lock:
            self.errors.insert(0, f"{datetime.now():%H:%M:%S} {where}: {exc}")
            del self.errors[20:]
        print(f"ERROR in {where}: {exc}", file=sys.stderr)
        traceback.print_exc()


STATE = State()
ARGS: argparse.Namespace


def _dir_stats(path: str, suffix: str) -> tuple[int, int]:
    count = size = 0
    if os.path.isdir(path):
        for e in os.scandir(path):
            if e.name.endswith(suffix):
                count += 1
                size += e.stat().st_size
    return count, size


def human(n: int) -> str:
    for unit in ("B", "KB", "MB", "GB"):
        if n < 1024 or unit == "GB":
            return f"{n:.0f} {unit}" if unit == "B" else f"{n:.1f} {unit}"
        n /= 1024
    return f"{n:.1f} GB"


def ago(dt: datetime | None) -> str:
    if dt is None:
        return "never"
    seconds = (datetime.now(timezone.utc) - dt).total_seconds()
    if seconds < 60:
        return f"{int(seconds)}s ago"
    if seconds < 3600:
        return f"{int(seconds / 60)}m ago"
    return f"{int(seconds / 3600)}h ago"


def snapshot() -> dict:
    incoming_n, incoming_b = _dir_stats(ARGS.incoming, ".omi")
    audio_n, audio_b = _dir_stats(ARGS.audio, ".omi")
    text_n, _ = _dir_stats(ARGS.text, ".json")
    notes_n, _ = _dir_stats(ARGS.vault, ".md")
    with STATE.lock:
        return {
            "ok": True,
            "model_ready": STATE.model_ready,
            "uptime_seconds": int(
                (datetime.now(timezone.utc) - STATE.started).total_seconds()),
            "queue": {"count": incoming_n, "bytes": incoming_b},
            "audio": {"count": audio_n, "bytes": audio_b},
            "transcripts": text_n,
            "notes": notes_n,
            "kept": STATE.kept,
            "dropped": STATE.dropped,
            "last_pass": STATE.last_pass.isoformat() if STATE.last_pass else None,
            "last_upload": (STATE.last_upload.isoformat()
                            if STATE.last_upload else None),
            "errors": list(STATE.errors),
            "recent": list(STATE.recent),
        }


PAGE = """<!doctype html><meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1">
<title>omi capture</title>
<style>
 :root{{color-scheme:dark light}}
 body{{font:15px/1.5 ui-sans-serif,system-ui,sans-serif;max-width:52rem;
   margin:2rem auto;padding:0 1rem}}
 h1{{font-size:1.3rem;margin:0 0 .2rem}}
 .sub{{opacity:.6;font-size:.85rem;margin-bottom:1.5rem}}
 .grid{{display:grid;grid-template-columns:repeat(auto-fit,minmax(9rem,1fr));
   gap:.75rem;margin-bottom:1.5rem}}
 .card{{border:1px solid color-mix(in srgb,currentColor 18%,transparent);
   border-radius:.5rem;padding:.7rem .85rem}}
 .k{{font-size:.75rem;opacity:.6;text-transform:uppercase;letter-spacing:.04em}}
 .v{{font-size:1.4rem;font-variant-numeric:tabular-nums}}
 .warn{{border-color:#c47}}
 table{{width:100%;border-collapse:collapse;font-size:.9rem}}
 td,th{{text-align:left;padding:.4rem .5rem;border-bottom:1px solid
   color-mix(in srgb,currentColor 12%,transparent);vertical-align:top}}
 th{{font-size:.75rem;opacity:.6;text-transform:uppercase}}
 td.t{{white-space:nowrap;opacity:.7;font-variant-numeric:tabular-nums}}
 .err{{color:#e66;font-size:.85rem;white-space:pre-wrap}}
 .empty{{opacity:.5;font-style:italic}}
</style>
<h1>omi capture</h1>
<div class=sub>{sub}</div>
<div class=grid>{cards}</div>
{errors}
<h2 style="font-size:1rem">Recent</h2>
<table><tr><th>Time</th><th>Segment</th><th></th></tr>{rows}</table>
<script>setTimeout(()=>location.reload(),15000)</script>
"""


class Handler(BaseHTTPRequestHandler):

    def _send(self, code: int, body: bytes, ctype: str) -> None:
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _json(self, code: int, payload: dict) -> None:
        self._send(code, json.dumps(payload).encode(), "application/json")

    def do_GET(self) -> None:  # noqa: N802
        if self.path == "/health":
            # Kept minimal and cheap: the phone hits this every 30 seconds.
            self._json(200, {"ok": True, "dir": ARGS.incoming})
        elif self.path == "/status.json":
            self._json(200, snapshot())
        elif self.path in ("/", "/index.html"):
            self._send(200, render_page().encode(), "text/html; charset=utf-8")
        else:
            self._json(404, {"error": "not found"})

    def do_POST(self) -> None:  # noqa: N802
        if not self.path.startswith("/upload/"):
            self._json(404, {"error": "not found"})
            return

        name = self.path[len("/upload/"):]
        if not proc_name_ok(name):
            self._json(400, {"error": f"unexpected segment name: {name!r}"})
            return

        try:
            length = int(self.headers.get("Content-Length", ""))
        except ValueError:
            self._json(411, {"error": "Content-Length required"})
            return
        if length <= 0 or length > 64 * 1024 * 1024:
            self._json(413, {"error": f"bad length {length}"})
            return

        dest = os.path.join(ARGS.incoming, name)
        # Already processed and moved to the audio directory, or still queued:
        # either way we have it. Answer with the hash we hold so the phone can
        # delete instead of retrying forever.
        for existing in (dest, os.path.join(ARGS.audio, name)):
            if os.path.exists(existing):
                self._json(200, {"sha256": sha256_file(existing),
                                 "bytes": os.path.getsize(existing),
                                 "duplicate": True})
                return

        import hashlib
        tmp = dest + ".part"
        digest = hashlib.sha256()
        written = 0
        try:
            with open(tmp, "wb") as fh:
                while written < length:
                    chunk = self.rfile.read(min(65536, length - written))
                    if not chunk:
                        break
                    fh.write(chunk)
                    digest.update(chunk)
                    written += len(chunk)
        except OSError as e:
            if os.path.exists(tmp):
                os.remove(tmp)
            self._json(500, {"error": str(e)})
            return

        if written != length:
            os.remove(tmp)
            self._json(400, {"error": f"short read: {written} of {length}"})
            return

        os.replace(tmp, dest)
        with STATE.lock:
            STATE.last_upload = datetime.now(timezone.utc)
        print(f"{datetime.now():%H:%M:%S}  received {name} ({written} bytes)",
              flush=True)
        self._json(200, {"sha256": digest.hexdigest(), "bytes": written,
                         "duplicate": False})

    def log_message(self, fmt: str, *args) -> None:
        pass


def proc_name_ok(name: str) -> bool:
    import re
    return bool(re.match(r"^seg-\d{10,16}\.omi$", name))


def sha256_file(path: str) -> str:
    import hashlib
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def render_page() -> str:
    s = snapshot()

    def card(k: str, v: str, warn: bool = False) -> str:
        cls = "card warn" if warn else "card"
        return (f'<div class="{cls}"><div class=k>{html.escape(k)}</div>'
                f'<div class=v>{html.escape(v)}</div></div>')

    queue_warn = s["queue"]["count"] > 20
    cards = "".join([
        card("Model", "ready" if s["model_ready"] else "loading",
             not s["model_ready"]),
        card("Queued", str(s["queue"]["count"]), queue_warn),
        card("Notes", str(s["notes"])),
        card("Kept / dropped", f'{s["kept"]} / {s["dropped"]}'),
        card("Audio held", human(s["audio"]["bytes"])),
        card("Last upload", ago(datetime.fromisoformat(s["last_upload"]))
             if s["last_upload"] else "never"),
    ])

    errors = ""
    if s["errors"]:
        errors = ("<h2 style='font-size:1rem'>Errors</h2><div class=err>"
                  + html.escape("\n".join(s["errors"])) + "</div>")

    if s["recent"]:
        rows = "".join(
            f'<tr><td class=t>{html.escape(r["time"])}</td>'
            f'<td class=t>{"KEEP" if r["kept"] else "DROP"}</td>'
            f'<td>{html.escape(r["text"] or r["reason"])}</td></tr>'
            for r in s["recent"]
        )
    else:
        rows = ('<tr><td colspan=3 class=empty>Nothing processed yet.</td></tr>')

    up = s["uptime_seconds"]
    sub = (f'up {up // 3600}h {(up % 3600) // 60}m · '
           f'last pass {ago(datetime.fromisoformat(s["last_pass"])) if s["last_pass"] else "never"} · '
           f'{s["transcripts"]} transcripts')

    return PAGE.format(sub=html.escape(sub), cards=cards, errors=errors,
                       rows=rows)


def worker() -> None:
    """Transcribe, decide, write notes. Everything slow happens here."""
    import onnx_asr

    print(f"loading {tx.MODEL} ...", flush=True)
    model = onnx_asr.load_model(tx.MODEL)
    with STATE.lock:
        STATE.model_ready = True
    print("  model ready", flush=True)

    ffmpeg = tx.find_ffmpeg()
    last_expiry = 0.0

    while True:
        try:
            pending = sorted(
                os.path.join(ARGS.incoming, f)
                for f in os.listdir(ARGS.incoming)
                if f.endswith(".omi")
            )
            changed = False
            for path in pending:
                # Per segment, not per pass. A single file the model chokes on
                # used to abort the whole loop, so everything behind it queued
                # up behind one bad recording and nothing drained at all.
                try:
                    d = proc.process_one(path, model, ffmpeg, ARGS.audio,
                                         ARGS.text, dry_run=False)
                except Exception as e:
                    STATE.note_error(os.path.basename(path), e)
                    # Moved aside rather than deleted or left in place. Deleting
                    # destroys audio we failed to read, and leaving it means
                    # retrying the same failure forever.
                    failed = os.path.join(ARGS.incoming, "failed")
                    os.makedirs(failed, exist_ok=True)
                    try:
                        os.replace(path, os.path.join(failed,
                                                      os.path.basename(path)))
                    except OSError:
                        pass
                    continue
                if d is None:
                    continue
                changed = True
                # Belt as well as braces: even with UTF-8 stdout, nothing about
                # printing a log line should be able to stop the pipeline.
                try:
                    print(f"  {'KEEP' if d.kept else 'DROP'}  {d.name}  "
                          f"{d.audio_seconds:.1f}s  {d.text[:80] or d.reason}",
                          flush=True)
                except Exception:
                    print(f"  {'KEEP' if d.kept else 'DROP'}  {d.name}  "
                          f"{d.audio_seconds:.1f}s  (text not printable)",
                          flush=True)
                with STATE.lock:
                    if d.kept:
                        STATE.kept += 1
                    else:
                        STATE.dropped += 1
                    STATE.recent.insert(0, {
                        "time": datetime.now().strftime("%H:%M:%S"),
                        "kept": d.kept,
                        "reason": d.reason,
                        "text": d.text[:200],
                    })
                    del STATE.recent[40:]

            if changed:
                # Rebuild notes rather than appending. A late segment belongs to
                # a conversation that may already have a note, and rewriting is
                # cheaper to reason about than patching.
                vaultmod.main_for(ARGS.text, ARGS.vault, ARGS.gap_minutes)

            with STATE.lock:
                STATE.last_pass = datetime.now(timezone.utc)

            if time.time() - last_expiry > 3600:
                proc.expire(ARGS.audio, ARGS.retain_days, dry_run=False)
                last_expiry = time.time()

        except Exception as e:  # keep the daemon alive; surface it on the page
            STATE.note_error("worker", e)

        time.sleep(ARGS.interval)


def install_task(python: str, script: str) -> None:
    """Register a logon task. Deliberately not a service: a service needs admin
    and would run without a user session, and nothing here needs that."""
    args = " ".join([
        f'"{script}"',
        f'--incoming "{ARGS.incoming}"',
        f'--audio "{ARGS.audio}"',
        f'--text "{ARGS.text}"',
        f'--vault "{ARGS.vault}"',
        f"--port {ARGS.port}",
    ])
    cmd = [
        "schtasks", "/Create", "/F",
        "/TN", "omi-capture",
        "/TR", f'"{python}" {args}',
        "/SC", "ONLOGON",
        "/RL", "LIMITED",
    ]
    subprocess.run(cmd, check=True)
    print("Registered scheduled task 'omi-capture' (runs at logon).")
    print("Start it now with:  schtasks /Run /TN omi-capture")
    print("Remove it with:     schtasks /Delete /TN omi-capture /F")


def main() -> None:
    global ARGS
    ap = argparse.ArgumentParser()
    ap.add_argument("--incoming", default="D:/omi/incoming")
    ap.add_argument("--audio", default="D:/omi/audio")
    ap.add_argument("--text", default="D:/omi/transcripts")
    ap.add_argument("--vault", default="D:/omi/vault/Omi Notes")
    ap.add_argument("--retain-days", type=int, default=7)
    ap.add_argument("--gap-minutes", type=int, default=10)
    ap.add_argument("--interval", type=int, default=30)
    ap.add_argument("--port", type=int, default=8723)
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--install-task", action="store_true")
    ARGS = ap.parse_args()

    if ARGS.install_task:
        install_task(sys.executable, os.path.abspath(__file__))
        return

    for d in (ARGS.incoming, ARGS.audio, ARGS.text, ARGS.vault):
        os.makedirs(d, exist_ok=True)

    threading.Thread(target=worker, daemon=True).start()

    server = ThreadingHTTPServer((ARGS.host, ARGS.port), Handler)
    print(f"omi capture on http://localhost:{ARGS.port}/  "
          f"(receiving into {ARGS.incoming})", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("stopping", file=sys.stderr)


if __name__ == "__main__":
    main()
