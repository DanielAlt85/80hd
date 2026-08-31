"""Read a .omi segment written by the phone.

Format is documented in lib/segment_writer.dart. This is the other half of it:
if this cannot reconstruct a burst, the capture is worthless no matter how
clean the logs looked.

Usage:
    python read_segment.py seg-1788207093804.omi
    python read_segment.py seg-*.omi --opus out.opus
"""

from __future__ import annotations

import argparse
import glob
import struct
import sys
from dataclasses import dataclass
from datetime import datetime, timezone

import ogg_opus

MAGIC = b"OMICAP01"
HEADER_LEN = 32
FRAME_MS = 20


@dataclass
class Frame:
    offset_ms: int
    index: int
    opus: bytes


@dataclass
class Segment:
    path: str
    start_epoch_ms: int
    codec_id: int
    sample_rate: int
    frames: list[Frame]

    @property
    def started_at(self) -> datetime:
        return datetime.fromtimestamp(self.start_epoch_ms / 1000, tz=timezone.utc)

    @property
    def audio_ms(self) -> int:
        return len(self.frames) * FRAME_MS

    @property
    def wall_ms(self) -> int:
        return self.frames[-1].offset_ms if self.frames else 0


def read(path: str) -> Segment:
    with open(path, "rb") as fh:
        blob = fh.read()

    if len(blob) < HEADER_LEN:
        raise ValueError(f"{path}: too short to hold a header")
    if blob[:8] != MAGIC:
        raise ValueError(f"{path}: bad magic {blob[:8]!r}")

    start_epoch_ms, codec_id, sample_rate = struct.unpack_from("<QBI", blob, 8)

    frames: list[Frame] = []
    pos = HEADER_LEN
    while pos + 8 <= len(blob):
        offset_ms, index, frame_len = struct.unpack_from("<IHH", blob, pos)
        pos += 8
        if pos + frame_len > len(blob):
            print(
                f"  truncated final record: wanted {frame_len} bytes, "
                f"{len(blob) - pos} left. Ignoring it.",
                file=sys.stderr,
            )
            break
        frames.append(Frame(offset_ms, index, blob[pos : pos + frame_len]))
        pos += frame_len

    return Segment(path, start_epoch_ms, codec_id, sample_rate, frames)


def index_discontinuities(seg: Segment) -> list[tuple[int, int, int]]:
    """(position, expected, got) wherever the device's counter jumped.

    The counter is 16 bit and wraps, which is not a discontinuity.
    """
    out = []
    for i in range(1, len(seg.frames)):
        expected = (seg.frames[i - 1].index + 1) & 0xFFFF
        got = seg.frames[i].index
        if got != expected:
            out.append((i, expected, got))
    return out


def describe(seg: Segment) -> None:
    print(f"{seg.path}")
    print(f"  started      {seg.started_at.astimezone().strftime('%Y-%m-%d %H:%M:%S')}")
    print(f"  codec        {seg.codec_id} ({'Opus' if seg.codec_id == 21 else '?'})"
          f"  {seg.sample_rate} Hz")
    print(f"  frames       {len(seg.frames)}")
    print(f"  opus bytes   {sum(len(f.opus) for f in seg.frames)}")
    print(f"  audio        {seg.audio_ms / 1000:.2f}s at {FRAME_MS}ms/frame")
    print(f"  wall clock   {seg.wall_ms / 1000:.2f}s from first to last arrival")

    if seg.frames:
        sizes = [len(f.opus) for f in seg.frames]
        print(f"  frame size   min {min(sizes)}  max {max(sizes)}  "
              f"mean {sum(sizes) / len(sizes):.1f}")
        bitrate = sum(sizes) * 8 / (seg.audio_ms / 1000)
        print(f"  bitrate      {bitrate / 1000:.1f} kbps")

    gaps = index_discontinuities(seg)
    if not gaps:
        print("  index        continuous, no lost frames")
        return

    print(f"  index        {len(gaps)} discontinuities")
    strides = []
    for pos, expected, got in gaps[:10]:
        missing = (got - expected) & 0xFFFF
        at = seg.frames[pos].offset_ms
        print(f"    at {at / 1000:7.2f}s  frame {pos:5d}  "
              f"expected {expected} got {got}  ({missing} missing)")
        strides.append(pos)
    if len(gaps) > 10:
        print(f"    ... and {len(gaps) - 10} more")

    # Loss is irregular. A fixed stride and a fixed size is the device doing
    # something on a schedule, not the radio dropping packets.
    if len(strides) > 2:
        deltas = [b - a for a, b in zip(strides, strides[1:])]
        misses = {(got - expected) & 0xFFFF for _, expected, got in gaps}
        if len(set(deltas)) == 1 and len(misses) == 1:
            print(f"  NOTE         every {deltas[0]} frames, exactly "
                  f"{misses.pop()} index skipped, without fail.")
            print("               That is a pattern, not packet loss.")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("paths", nargs="+")
    ap.add_argument(
        "--opus",
        metavar="OUT",
        help="mux the frames into a playable Ogg Opus file. With several "
             "inputs they are concatenated in the order given.",
    )
    args = ap.parse_args()

    paths: list[str] = []
    for p in args.paths:
        paths.extend(sorted(glob.glob(p)) or [p])

    segments: list[Segment] = []
    for path in paths:
        try:
            seg = read(path)
        except (OSError, ValueError) as e:
            print(f"{path}: {e}", file=sys.stderr)
            continue
        segments.append(seg)
        describe(seg)
        print()

    if args.opus and segments:
        frames = [f.opus for seg in segments for f in seg.frames]
        rate = segments[0].sample_rate
        n = ogg_opus.write(args.opus, frames, input_rate=rate)
        print(f"wrote {args.opus}: {n} frames, {n * FRAME_MS / 1000:.2f}s")
        if len(segments) > 1:
            # Concatenating discards the silence between bursts, which can be
            # hours. Fine for listening, wrong for anything timed.
            print("  note: bursts are butted together, gaps between them are "
                  "not represented")


if __name__ == "__main__":
    main()
