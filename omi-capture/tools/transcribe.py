"""Transcribe captured segments with Parakeet, locally.

Chain: .omi segment -> Ogg Opus (pure Python mux) -> 16 kHz mono PCM (ffmpeg)
-> Parakeet TDT 0.6B v3 via ONNX Runtime.

Nothing leaves this machine. That was the point of the whole exercise.

Not Whisper: it hallucinates fluent text into silence, and silence is most of
what a pendant hears. Parakeet returns nothing when there is nothing, which is
the behaviour that matters here.

Usage:
    python transcribe.py D:/omi/incoming/*.omi
    python transcribe.py D:/omi/incoming --json D:/omi/work/transcripts.json
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from dataclasses import asdict, dataclass
from datetime import datetime

import ogg_opus
import read_segment

MODEL = "nemo-parakeet-tdt-0.6b-v3"


def find_ffmpeg() -> str:
    found = shutil.which("ffmpeg")
    if found:
        return found
    # winget installs to a versioned path that is only on the PATH of shells
    # started after the install, which is rarely the shell we are in.
    root = os.path.expandvars(r"%LOCALAPPDATA%\Microsoft\WinGet\Packages")
    for dirpath, _, files in os.walk(root):
        if "ffmpeg.exe" in files:
            return os.path.join(dirpath, "ffmpeg.exe")
    raise FileNotFoundError("ffmpeg not found; install it or put it on PATH")


@dataclass
class Transcript:
    segment: str
    started_at: str
    audio_seconds: float
    text: str
    transcribe_seconds: float
    realtime_factor: float
    frames: int
    index_discontinuities: int


def to_wav(seg: read_segment.Segment, ffmpeg: str, out_path: str) -> None:
    """Segment -> 16 kHz mono WAV, via an Ogg container ffmpeg understands."""
    with tempfile.NamedTemporaryFile(suffix=".opus", delete=False) as tmp:
        opus_path = tmp.name
    try:
        ogg_opus.write(opus_path, [f.opus for f in seg.frames],
                       input_rate=seg.sample_rate)
        subprocess.run(
            [ffmpeg, "-hide_banner", "-loglevel", "error", "-y",
             "-i", opus_path, "-ar", "16000", "-ac", "1", out_path],
            check=True,
        )
    finally:
        os.unlink(opus_path)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("paths", nargs="+", help="segment files, globs, or a directory")
    ap.add_argument("--json", help="write results here as well as to stdout")
    ap.add_argument("--keep-wav", metavar="DIR",
                    help="keep the decoded audio, for listening to what the "
                         "model actually heard")
    args = ap.parse_args()

    paths: list[str] = []
    for p in args.paths:
        if os.path.isdir(p):
            paths.extend(sorted(glob.glob(os.path.join(p, "*.omi"))))
        else:
            paths.extend(sorted(glob.glob(p)) or [p])
    if not paths:
        print("no segments found", file=sys.stderr)
        sys.exit(1)

    ffmpeg = find_ffmpeg()

    import onnx_asr  # slow import, so not at module scope

    print(f"loading {MODEL} ...", flush=True)
    t0 = time.time()
    model = onnx_asr.load_model(MODEL)
    print(f"  ready in {time.time() - t0:.1f}s", flush=True)

    if args.keep_wav:
        os.makedirs(args.keep_wav, exist_ok=True)

    results: list[Transcript] = []
    total_audio = 0.0
    total_time = 0.0

    for path in paths:
        try:
            seg = read_segment.read(path)
        except (OSError, ValueError) as e:
            print(f"{os.path.basename(path)}: {e}", file=sys.stderr)
            continue
        if not seg.frames:
            print(f"{os.path.basename(path)}: no frames, skipping")
            continue

        name = os.path.basename(path)
        if args.keep_wav:
            wav_path = os.path.join(args.keep_wav, name.replace(".omi", ".wav"))
            to_wav(seg, ffmpeg, wav_path)
            cleanup = None
        else:
            with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
                wav_path = tmp.name
            to_wav(seg, ffmpeg, wav_path)
            cleanup = wav_path

        try:
            t0 = time.time()
            text = model.recognize(wav_path)
            elapsed = time.time() - t0
        finally:
            if cleanup:
                os.unlink(cleanup)

        audio_s = seg.audio_ms / 1000
        total_audio += audio_s
        total_time += elapsed

        r = Transcript(
            segment=name,
            started_at=seg.started_at.astimezone().isoformat(),
            audio_seconds=round(audio_s, 2),
            text=text.strip(),
            transcribe_seconds=round(elapsed, 2),
            realtime_factor=round(elapsed / audio_s, 3) if audio_s else 0.0,
            frames=len(seg.frames),
            index_discontinuities=len(read_segment.index_discontinuities(seg)),
        )
        results.append(r)

        stamp = seg.started_at.astimezone().strftime("%H:%M:%S")
        print(f"\n[{stamp}] {name}  {audio_s:.1f}s  "
              f"({elapsed:.1f}s, {r.realtime_factor:.2f}x realtime)")
        print(f"  {text.strip() or '(nothing recognised)'}")

    if total_audio:
        print(f"\n{len(results)} segments, {total_audio:.1f}s of audio in "
              f"{total_time:.1f}s — {total_audio / total_time:.1f}x faster "
              f"than realtime")

    if args.json:
        os.makedirs(os.path.dirname(args.json) or ".", exist_ok=True)
        with open(args.json, "w", encoding="utf-8") as fh:
            json.dump([asdict(r) for r in results], fh, indent=2,
                      ensure_ascii=False)
        print(f"wrote {args.json}")


if __name__ == "__main__":
    main()
