"""Turn transcripts into voice notes in the vault.

One note per conversation, not per burst. The pendant's detector fires on
sound, so a single conversation arrives as a scatter of bursts with silences
between them; a note per burst would be a vault full of fragments. Bursts
closer together than the gap threshold are one conversation.

Flat vault, no folders, no index notes. Notes link to each other; nothing
maintains a list.

The raw transcript is what gets written. Cleanup — correcting against a
glossary, making it readable, summarising — is a later stage that reads these,
and the raw text stays beside whatever it produces. A cleanup pass that loses
something has to be recoverable.

Regenerating is safe: notes are keyed by conversation start, so a late-arriving
segment rewrites its conversation's note rather than creating a second one.

Usage:
    python vault.py
    python vault.py --gap-minutes 15 --dry-run
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import re
from dataclasses import dataclass
from datetime import datetime, timedelta

# Bursts further apart than this start a new conversation. Ten minutes is a
# guess that wants revisiting against real days: too short splits one meeting
# into five notes, too long welds the morning to the afternoon.
DEFAULT_GAP = timedelta(minutes=10)


@dataclass
class Entry:
    started_at: datetime
    audio_seconds: float
    text: str
    segment: str
    discontinuities: int

    @property
    def ended_at(self) -> datetime:
        return self.started_at + timedelta(seconds=self.audio_seconds)


def load(text_dir: str) -> list[Entry]:
    entries = []
    for path in sorted(glob.glob(os.path.join(text_dir, "*.json"))):
        with open(path, encoding="utf-8") as fh:
            d = json.load(fh)
        entries.append(
            Entry(
                started_at=datetime.fromisoformat(d["started_at"]),
                audio_seconds=float(d["audio_seconds"]),
                text=d["text"],
                segment=d["segment"],
                discontinuities=int(d.get("index_discontinuities", 0)),
            )
        )
    entries.sort(key=lambda e: e.started_at)
    return entries


def group(entries: list[Entry], gap: timedelta) -> list[list[Entry]]:
    conversations: list[list[Entry]] = []
    for e in entries:
        if conversations and e.started_at - conversations[-1][-1].ended_at <= gap:
            conversations[-1].append(e)
        else:
            conversations.append([e])
    return conversations


def slug(dt: datetime) -> str:
    return dt.strftime("%Y-%m-%d %H%M")


def render(convo: list[Entry]) -> str:
    start = convo[0].started_at
    end = convo[-1].ended_at
    speech = sum(e.audio_seconds for e in convo)
    span = (end - start).total_seconds()
    lost = sum(e.discontinuities for e in convo)

    lines: list[str] = []
    lines.append("---")
    lines.append(f"date: {start.strftime('%Y-%m-%d')}")
    lines.append(f"start: {start.strftime('%H:%M:%S')}")
    lines.append(f"end: {end.strftime('%H:%M:%S')}")
    lines.append(f"speech_seconds: {round(speech, 1)}")
    lines.append(f"elapsed_seconds: {round(span, 1)}")
    lines.append(f"bursts: {len(convo)}")
    lines.append("source: omi-cv1")
    lines.append("transcript: raw")
    lines.append("speakers: unattributed")
    lines.append("---")
    lines.append("")
    lines.append(f"# {start.strftime('%A %-d %B, %-I:%M %p')}"
                 if os.name != "nt"
                 else f"# {start.strftime('%A %d %B, %I:%M %p').replace(' 0', ' ')}")
    lines.append("")

    if lost:
        lines.append(f"> {lost} packet gap(s) in this conversation. Speech the "
                     f"pendant captured did not reach the phone, so something "
                     f"is missing below and it is not marked inline.")
        lines.append("")

    # Elapsed is wall clock, speech is what was actually transmitted. The
    # difference is silence, and saying so stops the reader assuming the
    # transcript is continuous.
    if span > speech * 1.5:
        quiet = round((span - speech) / 60, 1)
        lines.append(f"> Spans {round(span / 60, 1)} minutes but contains "
                     f"{round(speech / 60, 1)} minutes of speech. "
                     f"{quiet} minutes of silence between bursts.")
        lines.append("")

    for e in convo:
        lines.append(f"**{e.started_at.strftime('%H:%M:%S')}**  {e.text}")
        lines.append("")

    lines.append("---")
    lines.append("")
    lines.append("Raw transcript, uncorrected. Speaker labels are absent rather "
                 "than guessed.")
    lines.append("")
    return "\n".join(lines)


def title(convo: list[Entry]) -> str:
    """Filename stem. Time-keyed, so a rerun rewrites rather than duplicates.

    Deliberately not derived from the content: a title generated from a raw
    transcript changes whenever the transcript changes, and a note that renames
    itself breaks every link into it.
    """
    return f"{slug(convo[0].started_at)} voice note"


def main_for(text_dir: str, vault_dir: str, gap_minutes: int,
             dry_run: bool = False) -> int:
    """The daemon calls this directly rather than shelling out to main()."""
    os.makedirs(vault_dir, exist_ok=True)
    entries = load(text_dir)
    if not entries:
        return 0

    written = 0
    for convo in group(entries, timedelta(minutes=gap_minutes)):
        path = os.path.join(vault_dir, f"{title(convo)}.md")
        body = render(convo)
        if os.path.exists(path):
            with open(path, encoding="utf-8") as fh:
                if fh.read() == body:
                    continue
        if not dry_run:
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(body)
        written += 1
    return written


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--text", default="D:/omi/transcripts")
    ap.add_argument("--vault", default="D:/omi/vault/Omi Notes")
    ap.add_argument("--gap-minutes", type=int, default=10)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    os.makedirs(args.vault, exist_ok=True)
    entries = load(args.text)
    if not entries:
        print("no transcripts")
        return

    conversations = group(entries, timedelta(minutes=args.gap_minutes))
    print(f"{len(entries)} transcript(s) -> {len(conversations)} conversation(s)")

    written = 0
    for convo in conversations:
        name = f"{title(convo)}.md"
        path = os.path.join(args.vault, name)
        body = render(convo)

        if os.path.exists(path):
            with open(path, encoding="utf-8") as fh:
                if fh.read() == body:
                    print(f"  unchanged  {name}")
                    continue

        preview = re.sub(r"\s+", " ", convo[0].text)[:70]
        print(f"  {'would write' if args.dry_run else 'wrote'}  {name}  "
              f"({len(convo)} burst(s))  {preview}")
        if not args.dry_run:
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(body)
        written += 1

    print(f"{written} note(s) {'would change' if args.dry_run else 'written'}")


if __name__ == "__main__":
    main()
