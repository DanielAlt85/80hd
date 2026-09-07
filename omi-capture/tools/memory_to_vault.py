#!/usr/bin/env python3
"""Mirror Claude Code's persistent memory into the Obsidian vault.

One-way: the memory directory stays the source of truth (Claude reads and
writes it every session); the vault gets a readable copy of each memory as a
note that follows the same conventions vault.py uses for voice notes:

  - `categories:` links ([[Claude memory]]), `topics:` links for what the note
    is about, `tags:` a closed kind-of-note vocabulary (reference/memory),
    bare dates, no folders.
  - The memory body is kept verbatim underneath a one-line summary, so a bad
    title never costs the content.
  - `[[slug]]` cross-links between memories are rewritten to the titles the
    notes get here, so they resolve in the graph.

Re-running overwrites only notes it wrote before (marked by `memory_file:`), so
a hand-edited note with the same title is never clobbered silently: it is
reported instead.

usage: memory_to_vault.py [--memory DIR] [--vault DIR] [--dry-run]
"""
from __future__ import annotations

import argparse
import os
import re
import sys
from datetime import date, datetime

DEFAULT_MEMORY = os.path.expanduser(r"~\.claude\projects\C--Users-dca72\memory")
DEFAULT_VAULT = r"D:\omi\vault\Omi Notes"
CATEGORY = "Claude memory"
INDEX_TITLE = "Claude memory"
ILLEGAL = re.compile(r'[<>:"/\\|?*\[\]#^]')

# Keyword -> topic link. Small and hand-kept on purpose: topics are what a
# person would search for, not every noun in the file.
TOPIC_RULES = [
    (re.compile(r"ornament|altbach|alt-mb|kicad|pcb", re.I), ["Altbach ornament", "PCB design"]),
    (re.compile(r"\b80hd\b", re.I), ["80hd"]),
    (re.compile(r"\bomi\b", re.I), ["Omi"]),
    (re.compile(r"brimjob", re.I), ["Brimjob"]),
    (re.compile(r"nfc", re.I), ["NFC player"]),
    (re.compile(r"macbook|mbp|mac-rescue", re.I), ["MacBook Pro recovery"]),
    (re.compile(r"openclaw|hermes", re.I), ["Agent systems"]),
    (re.compile(r"telegram|parakeet|whisper", re.I), ["Voice interaction"]),
    (re.compile(r"kanban|triage", re.I), ["Agent triage"]),
    (re.compile(r"vault|obsidian", re.I), ["Obsidian vault"]),
]


def parse_frontmatter(text: str) -> tuple[dict, str]:
    if not text.startswith("---"):
        return {}, text
    end = text.find("\n---", 3)
    if end < 0:
        return {}, text
    head, body = text[3:end], text[end + 4:]
    meta: dict = {}
    cur = None
    for line in head.splitlines():
        if not line.strip():
            continue
        m = re.match(r"^(\w[\w-]*):\s*(.*)$", line)
        if m and not line.startswith(" "):
            key, val = m.group(1), m.group(2).strip()
            meta[key] = val
            cur = key
        elif line.startswith(" ") and cur:
            m2 = re.match(r"^\s+(\w[\w-]*):\s*(.*)$", line)
            if m2:
                meta[f"{cur}.{m2.group(1)}"] = m2.group(2).strip()
    return meta, body.lstrip("\n")


# Hand-kept titles: a description's first clause is a fine default but a title
# is something you scan a list by, so the known files get a deliberate one.
TITLE_OVERRIDES = {
    "feedback_80hd_constraints.md": "80hd vault and docs constraints",
    "project_80hd_triage.md": "80hd triage surface",
    "project_80hd_voice.md": "80hd voice in and out",
    "project_brimjob.md": "brimjob.com bar pour-map",
    "project_mbp_recovery.md": "MacBook Pro recovery",
    "project_nfc_player.md": "Spotify NFC player on the Pi 5",
    "project_omi_capture.md": "Omi CV1 capture pipeline",
    "project_ornament_tooling.md": "Altbach ornament PCB",
    "reference_agent_systems.md": "OpenClaw and Hermes Agent",
    "feedback_vault_mirror.md": "Vault mirror of Claude memory",
}


def title_from(meta: dict, fname: str) -> str:
    if fname in TITLE_OVERRIDES:
        return TITLE_OVERRIDES[fname]
    desc = meta.get("description", "")
    # first clause of the description reads like a title
    t = re.split(r"\s+[—–-]{1,2}\s+|:\s+|;\s+|\(", desc, maxsplit=1)[0].strip()
    if not t or len(t) > 70:
        t = re.sub(r"[_-]+", " ", os.path.splitext(fname)[0]).strip().capitalize()
    t = t.rstrip(".")
    return ILLEGAL.sub("", t)[:80].strip()


def created_from(meta: dict, path: str) -> str:
    v = meta.get("metadata.modified") or meta.get("modified")
    if v:
        m = re.match(r"(\d{4}-\d{2}-\d{2})", v)
        if m:
            return m.group(1)
    return date.fromtimestamp(os.path.getmtime(path)).isoformat()


def topics_for(text: str) -> list[str]:
    out: list[str] = []
    for rx, tops in TOPIC_RULES:
        if rx.search(text):
            for t in tops:
                if t not in out:
                    out.append(t)
    return out


def link(name: str) -> str:
    return '"[[' + name + ']]"'


def build_notes(memory_dir: str) -> list[dict]:
    notes = []
    for fname in sorted(os.listdir(memory_dir)):
        if not fname.endswith(".md") or fname == "MEMORY.md":
            continue
        path = os.path.join(memory_dir, fname)
        text = open(path, encoding="utf-8").read()
        meta, body = parse_frontmatter(text)
        title = title_from(meta, fname)
        notes.append({
            "file": fname, "path": path, "meta": meta, "body": body,
            "title": f"Memory - {title}",
            "slug": meta.get("name", os.path.splitext(fname)[0]),
            "type": meta.get("metadata.type") or meta.get("type") or "note",
            "created": created_from(meta, path),
            "description": meta.get("description", ""),
        })
    return notes


def render(note: dict, slug_to_title: dict) -> str:
    body = note["body"]
    # rewrite [[slug]] links between memories to the vault titles
    def sub(m):
        s = m.group(1)
        return f"[[{slug_to_title.get(s, s)}]]"
    body = re.sub(r"\[\[([^\]|]+)\]\]", sub, body)
    lines = ["---", "categories:", f"  - {link(CATEGORY)}", f"created: {note['created']}"]
    tops = topics_for(note["description"] + " " + body)
    if tops:
        lines.append("topics:")
        lines.extend(f"  - {link(t)}" for t in tops)
    lines += ["tags:", "  - reference/memory",
              f"memory_type: {note['type']}",
              "source: claude-code-memory",
              f"memory_file: {note['file']}", "---", ""]
    lines.append(f"# {note['title'][len('Memory - '):]}")
    lines.append("")
    if note["description"]:
        lines.append(f"> {note['description']}")
        lines.append("")
    lines.append(body.rstrip() + "\n")
    lines.append("")
    lines.append("---")
    lines.append("")
    lines.append(f"Mirrored from Claude Code memory `{note['file']}` (type: {note['type']}). "
                 "The memory directory is the source of truth; edit there, not here. "
                 f"Index: [[{INDEX_TITLE}]].")
    return "\n".join(lines) + "\n"


def render_index(notes: list[dict]) -> str:
    lines = ["---", "categories:", f"  - {link(CATEGORY)}", f"created: {date.today().isoformat()}",
             "tags:", "  - reference/memory", "source: claude-code-memory", "memory_file: MEMORY.md",
             "---", "", f"# {INDEX_TITLE}", "",
             "> What Claude Code carries between sessions on the Acer, mirrored here so the "
             "projects, decisions and lessons live beside the voice notes. One note per memory; "
             "the source of truth is `~/.claude/projects/C--Users-dca72/memory/`.", ""]
    by_type: dict[str, list[dict]] = {}
    for n in notes:
        by_type.setdefault(n["type"], []).append(n)
    label = {"project": "Projects", "feedback": "How Daniel wants things done", "reference": "Reference",
             "user": "About Daniel", "note": "Other"}
    for t in ("project", "feedback", "reference", "user", "note"):
        if t not in by_type:
            continue
        lines.append(f"## {label[t]}")
        lines.append("")
        for n in by_type[t]:
            lines.append(f"- [[{n['title']}]] — {n['description']}")
        lines.append("")
    lines.append("---")
    lines.append("")
    lines.append(f"Regenerated by `omi-capture/tools/memory_to_vault.py` on {datetime.now():%Y-%m-%d %H:%M}.")
    return "\n".join(lines) + "\n"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--memory", default=DEFAULT_MEMORY)
    ap.add_argument("--vault", default=DEFAULT_VAULT)
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()
    notes = build_notes(a.memory)
    slug_to_title = {n["slug"]: n["title"] for n in notes}
    # older memories link by file stem too
    for n in notes:
        slug_to_title.setdefault(os.path.splitext(n["file"])[0], n["title"])
    written, skipped = 0, []
    for n in notes:
        out = os.path.join(a.vault, n["title"] + ".md")
        if os.path.exists(out):
            existing = open(out, encoding="utf-8").read()
            if "memory_file:" not in existing.split("---", 2)[1]:
                skipped.append(out)
                continue
        if not a.dry_run:
            with open(out, "w", encoding="utf-8", newline="\n") as fh:
                fh.write(render(n, slug_to_title))
        written += 1
        print("  wrote" if not a.dry_run else "  would write", os.path.basename(out))
    idx = os.path.join(a.vault, INDEX_TITLE + ".md")
    if not a.dry_run:
        with open(idx, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(render_index(notes))
    print(f"{written} memory note(s) + index -> {a.vault}")
    for s in skipped:
        print("  SKIPPED (hand-written note with that title exists):", s)
    return 0


if __name__ == "__main__":
    sys.exit(main())
