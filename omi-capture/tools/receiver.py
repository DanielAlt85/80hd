"""Receives segment files from the phone.

Deliberately small and boring. It listens on the tailnet, writes what it is
given into an incoming directory, and answers with a SHA-256 of what actually
landed on disk.

That hash is the whole point. The phone does not delete its copy because the
upload returned 200; it deletes because the host proved it holds the same bytes.
Nothing frees its own copy — the next stage's receipt does.

Run:
    python receiver.py --dir D:/omi/incoming --port 8723
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# A segment name as the phone generates it. Anything else is refused outright
# rather than sanitised: the only writer is our own app, so a surprising name
# means something is wrong, not that we should be clever about it.
NAME = re.compile(r"^seg-\d{10,16}\.omi$")

MAX_BYTES = 64 * 1024 * 1024


class Handler(BaseHTTPRequestHandler):
    directory = "."

    def _json(self, code: int, payload: dict) -> None:
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802
        if self.path == "/health":
            self._json(200, {"ok": True, "dir": self.directory})
        else:
            self._json(404, {"error": "not found"})

    def do_POST(self) -> None:  # noqa: N802
        if not self.path.startswith("/upload/"):
            self._json(404, {"error": "not found"})
            return

        name = self.path[len("/upload/"):]
        if not NAME.match(name):
            self._json(400, {"error": f"unexpected segment name: {name!r}"})
            return

        try:
            length = int(self.headers.get("Content-Length", ""))
        except ValueError:
            self._json(411, {"error": "Content-Length required"})
            return
        if length <= 0 or length > MAX_BYTES:
            self._json(413, {"error": f"bad length {length}"})
            return

        dest = os.path.join(self.directory, name)

        # Already have it: answer with the hash we hold rather than rewriting.
        # A phone that retries because it missed our reply gets the same receipt
        # and can delete, instead of uploading forever.
        if os.path.exists(dest):
            self._json(200, {"sha256": sha256_file(dest),
                             "bytes": os.path.getsize(dest),
                             "duplicate": True})
            return

        # Write to a temporary name first. A crash mid-upload must not leave a
        # truncated file sitting under a name the uploader will treat as done.
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
            os.path.exists(tmp) and os.remove(tmp)
            self._json(500, {"error": str(e)})
            return

        if written != length:
            os.remove(tmp)
            self._json(400, {"error": f"short read: {written} of {length}"})
            return

        os.replace(tmp, dest)
        received = datetime.now(timezone.utc).isoformat()
        print(f"{received}  {name}  {written} bytes", flush=True)
        self._json(200, {"sha256": digest.hexdigest(), "bytes": written,
                         "duplicate": False})

    def log_message(self, fmt: str, *args) -> None:
        # The default handler logs every request to stderr. We print what we
        # care about ourselves.
        pass


def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", default="D:/omi/incoming")
    ap.add_argument("--port", type=int, default=8723)
    # Binds to all interfaces so the tailnet address works. There is no
    # authentication here: this is only safe because it listens on a machine
    # whose only route from the phone is Tailscale. If that ever stops being
    # true this needs a token.
    ap.add_argument("--host", default="0.0.0.0")
    args = ap.parse_args()

    os.makedirs(args.dir, exist_ok=True)
    Handler.directory = args.dir

    server = ThreadingHTTPServer((args.host, args.port), Handler)
    print(f"receiving into {args.dir} on {args.host}:{args.port}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("stopping", file=sys.stderr)


if __name__ == "__main__":
    main()
