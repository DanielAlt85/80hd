"""Process incoming segments: transcribe, keep what has speech, drop what does not.

Roughly half of what the pendant sends is silence. Its detector is a trigger,
not a speech classifier: any sound past a threshold buys a fixed ten second
burst whether or not anyone kept talking. A door closing produces ten seconds of
nothing. Only the transcriber can tell the difference, so the decision lives
here rather than on the phone, which has no decoder.

An empty segment is deleted rather than archived. Keeping them costs disk and,
worse, each would eventually become a note about nothing.

Retention: transcribed audio is kept for a number of days and then removed. The
transcript stays. Audio is the sensitive artefact and the least useful one once
the words are out of it.

Usage:
    python process.py                     # one pass over D:/omi/incoming
    python process.py --watch             # keep going
    python process.py --dry-run           # decide, change nothing
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from datetime import datetime, timedelta

import ogg_opus
import read_segment
import transcribe as tx

# A transcript this short is not a sentence. Parakeet occasionally emits a
# single stray token from a door or a cough, and one word is not worth a note.
MIN_CHARS = 12

# Detects a transcript that is one token repeated, which is what a model
# produces when handed a hum or a fan rather than speech.
def _is_degenerate(text: str) -> bool:
    words = re.findall(r"\w+", text.lower())
    if len(words) < 4:
        return False
    return len(set(words)) <= 2


@dataclass
class Decision:
    name: str
    kept: bool
    reason: str
    text: str
    audio_seconds: float


def process_one(path: str, model, ffmpeg: str, audio_dir: str,
                text_dir: str, dry_run: bool) -> Decision | None:
    name = os.path.basename(path)
    try:
        seg = read_segment.read(path)
    except (OSError, ValueError) as e:
        print(f"  {name}: unreadable ({e}) — left in place for inspection")
        return None

    if not seg.frames:
        return Decision(name, False, "no frames", "", 0.0)

    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
        wav = tmp.name
    try:
        tx.to_wav(seg, ffmpeg, wav)
        text = model.recognize(wav).strip()
    finally:
        os.unlink(wav)

    audio_s = seg.audio_ms / 1000

    if not text:
        reason = "no speech"
    elif len(text) < MIN_CHARS:
        reason = f"too short ({len(text)} chars)"
    elif _is_degenerate(text):
        reason = "degenerate output, likely not speech"
    else:
        reason = "speech"

    keep = reason == "speech"
    if dry_run:
        return Decision(name, keep, reason, text, audio_s)

    if keep:
        stamp = seg.started_at.astimezone()
        stem = stamp.strftime("%Y-%m-%dT%H-%M-%S")
        with open(os.path.join(text_dir, f"{stem}.json"), "w",
                  encoding="utf-8") as fh:
            json.dump(
                {
                    "segment": name,
                    "started_at": stamp.isoformat(),
                    "audio_seconds": round(audio_s, 2),
                    "frames": len(seg.frames),
                    "index_discontinuities":
                        len(read_segment.index_discontinuities(seg)),
                    "text": text,
                },
                fh, indent=2, ensure_ascii=False,
            )
        shutil.move(path, os.path.join(audio_dir, name))
    else:
        os.remove(path)

    return Decision(name, keep, reason, text, audio_s)


def expire(audio_dir: str, days: int, dry_run: bool) -> int:
    """Delete audio older than the retention window. Transcripts stay."""
    if days <= 0:
        return 0
    cutoff = datetime.now() - timedelta(days=days)
    removed = 0
    for entry in os.scandir(audio_dir):
        if not entry.name.endswith(".omi"):
            continue
        if datetime.fromtimestamp(entry.stat().st_mtime) >= cutoff:
            continue
        print(f"  expiring {entry.name} (older than {days} days)")
        if not dry_run:
            os.remove(entry.path)
        removed += 1
    return removed


def run_pass(args, model, ffmpeg: str) -> int:
    pending = sorted(
        os.path.join(args.incoming, f)
        for f in os.listdir(args.incoming)
        if f.endswith(".omi")
    )
    if not pending:
        return 0

    print(f"{datetime.now():%H:%M:%S}  {len(pending)} segment(s)")
    kept = dropped = 0
    for path in pending:
        d = process_one(path, model, ffmpeg, args.audio, args.text, args.dry_run)
        if d is None:
            continue
        if d.kept:
            kept += 1
            print(f"  KEEP  {d.name}  {d.audio_seconds:.1f}s  {d.text[:90]}")
        else:
            dropped += 1
            print(f"  DROP  {d.name}  {d.audio_seconds:.1f}s  ({d.reason})")

    print(f"  kept {kept}, dropped {dropped}"
          + ("  [dry run, nothing changed]" if args.dry_run else ""))
    return len(pending)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--incoming", default="D:/omi/incoming")
    ap.add_argument("--audio", default="D:/omi/audio",
                    help="where kept audio lands, until it expires")
    ap.add_argument("--text", default="D:/omi/transcripts",
                    help="where transcripts land, and stay")
    ap.add_argument("--retain-days", type=int, default=7)
    ap.add_argument("--watch", action="store_true")
    ap.add_argument("--interval", type=int, default=60)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    for d in (args.incoming, args.audio, args.text):
        os.makedirs(d, exist_ok=True)

    ffmpeg = tx.find_ffmpeg()

    import onnx_asr

    print(f"loading {tx.MODEL} ...", flush=True)
    model = onnx_asr.load_model(tx.MODEL)
    print("  ready", flush=True)

    if not args.watch:
        run_pass(args, model, ffmpeg)
        expire(args.audio, args.retain_days, args.dry_run)
        return

    print(f"watching {args.incoming} every {args.interval}s", flush=True)
    last_expiry = 0.0
    try:
        while True:
            run_pass(args, model, ffmpeg)
            # Retention is a slow clock; no need to walk the directory every
            # time a segment lands.
            if time.time() - last_expiry > 3600:
                expire(args.audio, args.retain_days, args.dry_run)
                last_expiry = time.time()
            time.sleep(args.interval)
    except KeyboardInterrupt:
        print("stopping", file=sys.stderr)


if __name__ == "__main__":
    main()
