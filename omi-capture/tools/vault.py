"""Write voice notes into an Obsidian vault.

Conventions follow how Steph Ango (Obsidian's CEO) structures his own vault,
because an automated writer should follow a convention someone actually lives
with rather than one invented here:

  - Subject matter goes in `topics:` as wikilinks, never as tags. Links to notes
    that do not exist yet are the point, not a bug — an unresolved [[Sourdough]]
    still collects backlinks and shows in the graph, so the vault assembles
    itself without us creating anything.
  - `categories:` is the primary grouping and is also links.
  - `tags:` stay a small closed vocabulary describing the KIND of note, not what
    it is about. Nested as domain/facet.
  - Dates are bare YYYY-MM-DD. Folders are not used for organisation.
  - Properties earn their place by being something you would sort or filter by.
    Duration, burst counts and packet statistics are not, and are gone.

One note per conversation, not per recording. The pendant's detector fires on
sound, so one conversation arrives as a scatter of recordings.

Nothing is ever dropped. Music, television and unintelligible audio still get a
note, tagged by kind so they can be filtered or bulk-deleted later. The model
that classifies them is wrong sometimes, and deleting on its judgement is the
one irreversible act in this pipeline.

The raw transcript is always present, underneath whatever the model wrote. A bad
summary should be an annoyance, never a loss.
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import re
from dataclasses import dataclass, field
from datetime import datetime, timedelta

import summarize as summariser

# Recordings further apart than this start a new conversation. Ten minutes
# welded an entire afternoon into one note; four keeps a meeting together
# without joining breakfast to dinner.
DEFAULT_GAP_MINUTES = 4

CATEGORY = "Voice notes"

# 25 packets is half a second — roughly a short word. Below this the loss is
# real but inaudible, and saying so trains the reader to ignore the banner.
GAP_WARNING_PACKETS = 25

# Characters Windows and Obsidian will not accept in a filename.
ILLEGAL = re.compile(r'[\\/:*?"<>|#^\[\]]')


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


@dataclass
class Conversation:
    entries: list[Entry]
    summary: summariser.Summary = field(default_factory=summariser.Summary)

    @property
    def started_at(self) -> datetime:
        return self.entries[0].started_at

    @property
    def transcript(self) -> str:
        return " ".join(e.text for e in self.entries if e.text).strip()

    @property
    def lost_packets(self) -> int:
        return sum(e.discontinuities for e in self.entries)


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


def group(entries: list[Entry], gap: timedelta) -> list[Conversation]:
    out: list[list[Entry]] = []
    for e in entries:
        if out and e.started_at - out[-1][-1].ended_at <= gap:
            out[-1].append(e)
        else:
            out.append([e])
    return [Conversation(g) for g in out]


def link(name: str) -> str:
    """A wikilink safe to sit inside YAML."""
    return '"[[' + ILLEGAL.sub("", name).strip() + ']]"'


def stem(convo: Conversation) -> str:
    """`YYYY-MM-DD HHMM Descriptive phrase`, or just the timestamp.

    The date prefix keeps notes sortable and unique; the phrase makes them
    findable in the quick switcher. Kepano titles quick capture by timestamp and
    reserves sentence titles for distilled notes, and a meeting note in his
    vault is exactly this hybrid.
    """
    prefix = convo.started_at.strftime("%Y-%m-%d %H%M")
    title = convo.summary.title
    if not title:
        return prefix
    return f"{prefix} {ILLEGAL.sub('', title).strip()}"


def existing_path(vault: str, convo: Conversation) -> str | None:
    """Find a note already written for this conversation.

    Notes are matched on the timestamp prefix, not the whole filename. The
    descriptive half can change when a transcript is re-summarised, and renaming
    a note breaks every link into it — so an existing note keeps its name and
    only its contents are rewritten.
    """
    prefix = convo.started_at.strftime("%Y-%m-%d %H%M")
    for path in glob.glob(os.path.join(vault, f"{prefix}*.md")):
        return path
    return None


def render(convo: Conversation) -> str:
    s = convo.summary
    started = convo.started_at

    kind_tag = {
        "conversation": "voice/conversations",
        "monologue": "voice/monologues",
        "media": "voice/media",
    }.get(s.kind, "voice/unclear")

    lines: list[str] = ["---"]
    lines.append("categories:")
    lines.append(f"  - {link(CATEGORY)}")
    lines.append(f"created: {started.strftime('%Y-%m-%d')}")
    if s.topics:
        lines.append("topics:")
        lines.extend(f"  - {link(t)}" for t in s.topics)
    if s.people:
        lines.append("people:")
        lines.extend(f"  - {link(p)}" for p in s.people)
    lines.append("tags:")
    lines.append(f"  - {kind_tag}")
    lines.append("source: omi-cv1")
    lines.append("---")
    lines.append("")

    lines.append(f"# {s.title or started.strftime('%A %d %B, %I:%M %p')}")
    lines.append("")
    lines.append(f"*{started.strftime('%A %d %B %Y, %I:%M %p')}*")
    lines.append("")

    if s.summary:
        lines.append(f"> {s.summary}")
        lines.append("")

    # Only when enough was lost to swallow a word. Measured over four hours of
    # real capture the loss rate is 0.016% and no single gap exceeded two
    # packets — 40ms, inaudible. Warning about that taught the reader to ignore
    # the banner, which would cost us the one time it matters.
    if convo.lost_packets >= GAP_WARNING_PACKETS:
        lost_ms = convo.lost_packets * 20
        lines.append(f"> [!warning] {lost_ms / 1000:.1f}s of speech never "
                     f"reached the phone. This transcript has holes in it.")
        lines.append("")

    lines.append("## Transcript")
    lines.append("")
    for e in convo.entries:
        if e.text:
            lines.append(f"**{e.started_at.strftime('%H:%M')}** {e.text}")
            lines.append("")

    lines.append("---")
    lines.append("")
    lines.append("Raw transcript, uncorrected. Speech recognition makes "
                 "mistakes and speakers are not distinguished.")
    lines.append("")
    return "\n".join(lines)


def write_notes(text_dir: str, vault_dir: str, gap_minutes: int,
                dry_run: bool = False, verbose: bool = False) -> int:
    os.makedirs(vault_dir, exist_ok=True)
    entries = load(text_dir)
    if not entries:
        return 0

    conversations = group(entries, timedelta(minutes=gap_minutes))
    have_model = summariser.available()
    if verbose:
        print(f"{len(entries)} transcript(s) -> {len(conversations)} "
              f"conversation(s)"
              + ("" if have_model else "  [no model; titles will be timestamps]"))

    written = 0
    for convo in conversations:
        if have_model:
            convo.summary = summariser.summarize(convo.transcript)

        body = render(convo)
        path = existing_path(vault_dir, convo)
        if path is None:
            path = os.path.join(vault_dir, f"{stem(convo)}.md")
        elif os.path.exists(path):
            with open(path, encoding="utf-8") as fh:
                if fh.read() == body:
                    continue

        if verbose:
            print(f"  {'would write' if dry_run else 'wrote'}  "
                  f"{os.path.basename(path)}"
                  f"  [{convo.summary.kind}]")
        if not dry_run:
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(body)
        written += 1

    return written


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--text", default="D:/omi/transcripts")
    ap.add_argument("--vault", default="D:/omi/vault/Omi Notes")
    ap.add_argument("--gap-minutes", type=int, default=DEFAULT_GAP_MINUTES)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    n = write_notes(args.text, args.vault, args.gap_minutes,
                    dry_run=args.dry_run, verbose=True)
    print(f"{n} note(s) {'would change' if args.dry_run else 'written'}")


if __name__ == "__main__":
    main()
