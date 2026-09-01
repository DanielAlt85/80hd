"""Turn a raw transcript into the things a note needs: a title, a summary, topics.

This is the first stage in the pipeline that can be confidently wrong. Everything
before it is mechanical — bytes match a hash or they do not. A model inventing a
plausible summary of a conversation that did not happen is a different kind of
failure, and the mitigations here are deliberate:

  - The raw transcript is never replaced, only accompanied.
  - Every field is optional. A refusal or a malformed answer yields None, and the
    note is written without it rather than with a guess.
  - The model is asked to say when it cannot tell, and "unclear" is an accepted
    answer rather than one to retry until it produces something.

Runs against Ollama locally, so nothing leaves the machine.
"""

from __future__ import annotations

import json
import re
import urllib.error
import urllib.request
from dataclasses import dataclass, field

OLLAMA = "http://127.0.0.1:11434/api/chat"
MODEL = "qwen3:4b"

# Long enough to be worth summarising. Below this the transcript IS the summary.
MIN_CHARS = 80


@dataclass
class Summary:
    title: str | None = None
    summary: str | None = None
    topics: list[str] = field(default_factory=list)
    people: list[str] = field(default_factory=list)
    kind: str = "unclear"

    @property
    def is_speech(self) -> bool:
        """Whether this looks like someone talking, rather than media playing.

        The pendant hears whatever is in the room, including television, music
        and games. Those transcribe perfectly well and are worthless as notes —
        one real capture here was song lyrics from something playing nearby.
        Filing that as a voice note is worse than dropping it.
        """
        return self.kind in ("conversation", "monologue")


SYSTEM = """You label transcripts from a wearable voice recorder. The recorder \
hears whatever is nearby, so a transcript may be a real conversation, someone \
thinking out loud, or audio from a television, film, game or music playing in \
the room.

Transcripts are unpunctuated, contain false starts and filler, and the speech \
recogniser makes mistakes. Do not clean up or invent content.

Answer only with a JSON object, no prose and no code fence, with these keys:

  "kind":    one of "conversation", "monologue", "media", "unclear".
             "media" for television, film, music, games, podcasts, adverts.
             "unclear" if you genuinely cannot tell. Prefer "unclear" to guessing.
  "title":   a short specific phrase naming what this is about, 3 to 7 words.
             Not a summary, a name. Sentence case: capitalise only the first
             word and any proper nouns. Do NOT use Title Case.
             Good:  "Debugging the reconnect loop"
                    "Sunday plans and a Costco run"
             Bad:   "Debugging The Reconnect Loop"
                    "A Conversation About Plans"
             null if kind is "media" or "unclear".
  "summary": one plain sentence, under 25 words, saying what was discussed.
             Do not editorialise or infer intent. null if you cannot tell.
  "topics":  0 to 5 subjects, each a short noun phrase in sentence case, that a
             person might later search for. Concrete things actually discussed,
             not abstract themes. Empty list if unclear.
  "people":  names of people actually named in the transcript. Empty list if
             none. Never guess a name from context.

If the transcript is too garbled or too short to judge, return kind "unclear" \
with nulls and empty lists. That is a correct answer, not a failure."""


def _post(payload: dict, timeout: int) -> dict | None:
    req = urllib.request.Request(
        OLLAMA,
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as res:
            return json.loads(res.read())
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError, OSError):
        return None


def available() -> bool:
    try:
        with urllib.request.urlopen("http://127.0.0.1:11434/api/tags", timeout=5):
            return True
    except OSError:
        return False


def _extract_json(text: str) -> dict | None:
    """Pull the JSON object out of a reply that may be wrapped in prose or fences.

    Asking for JSON is not the same as getting JSON, and a model that adds a
    sentence of preamble should not cost us the whole result.
    """
    text = re.sub(r"<think>.*?</think>", "", text, flags=re.S).strip()
    text = re.sub(r"^```(?:json)?|```$", "", text, flags=re.M).strip()
    start, end = text.find("{"), text.rfind("}")
    if start == -1 or end <= start:
        return None
    try:
        return json.loads(text[start : end + 1])
    except json.JSONDecodeError:
        return None


# Returned as "people" by the model on real transcripts. A note linking to
# [[you]] or [[mom]] creates a junk entity note that every other note then
# links to, which is worse than having no people at all.
NOT_A_NAME = {
    "you", "i", "me", "he", "she", "they", "we", "us", "them", "him", "her",
    "someone", "somebody", "everyone", "nobody", "the speaker", "speaker",
    "narrator", "child", "kid", "parent", "unknown", "unclear", "n/a", "none",
    "the user", "user", "person", "people", "mom", "mum", "dad", "mama",
    "papa", "mother", "father",
}


def _clean_list(value, limit: int, *, names: bool = False) -> list[str]:
    if not isinstance(value, list):
        return []
    out = []
    for v in value:
        if not isinstance(v, str):
            continue
        v = v.strip().strip(".,;:").strip()
        # Wikilink syntax would nest badly once we wrap these ourselves.
        v = v.replace("[", "").replace("]", "")
        if not v or len(v) > 60:
            continue
        if v.lower() in {"unclear", "unknown", "n/a"}:
            continue
        if names and (v.lower() in NOT_A_NAME or not v[0].isupper()):
            continue
        out.append(v)
    # Case-insensitive dedupe, first spelling wins.
    seen, unique = set(), []
    for v in out:
        if v.lower() not in seen:
            seen.add(v.lower())
            unique.append(v)
    return unique[:limit]


def _sentence_case(s: str | None) -> str | None:
    """Kepano's titles are sentence case, and the model insists on Title Case.

    Words already containing an inner capital are left alone, so acronyms and
    names like "Costco" or "iPhone" survive.
    """
    if not s:
        return s
    words = s.split()
    out = []
    for i, w in enumerate(words):
        if i > 0 and w[1:] != w[1:].lower():
            out.append(w)          # inner capital: a name or acronym
        elif i > 0 and w[:1].isupper() and w[1:].islower() and len(w) > 3:
            out.append(w)          # probably a proper noun; leave it
        elif i == 0:
            out.append(w[:1].upper() + w[1:])
        else:
            out.append(w[:1].lower() + w[1:])
    return " ".join(out)


def _clean_text(value, limit: int) -> str | None:
    if not isinstance(value, str):
        return None
    v = " ".join(value.split()).strip().strip('"')
    if not v or v.lower() in {"unclear", "unknown", "null", "n/a", "none"}:
        return None
    # A title is a name, not an essay. Something far over the limit means the
    # model ignored the instruction, and a truncated sentence is worse than none.
    return v if len(v) <= limit else None


def summarize(text: str, *, timeout: int = 120) -> Summary:
    text = text.strip()
    if len(text) < MIN_CHARS:
        return Summary(kind="unclear")

    payload = {
        "model": MODEL,
        "stream": False,
        "format": "json",
        # qwen3 is a reasoning model and will spend thousands of tokens thinking
        # before answering, which took a 209-character transcript past a two
        # minute timeout on a GPU that fits the whole model. Labelling a
        # transcript does not need deliberation.
        "think": False,
        "options": {
            # Low but not zero. This is extraction, not writing; we want the
            # obvious answer, repeatably.
            "temperature": 0.2,
            "num_ctx": 8192,
        },
        "messages": [
            {"role": "system", "content": SYSTEM},
            {"role": "user", "content": f"Transcript:\n\n{text[:12000]}"},
        ],
    }

    res = _post(payload, timeout)
    if not res:
        return Summary(kind="unclear")

    data = _extract_json(res.get("message", {}).get("content", "") or "")
    if not data:
        return Summary(kind="unclear")

    kind = data.get("kind")
    if kind not in ("conversation", "monologue", "media", "unclear"):
        kind = "unclear"

    return Summary(
        title=_sentence_case(_clean_text(data.get("title"), 80)),
        summary=_clean_text(data.get("summary"), 300),
        topics=_clean_list(data.get("topics"), 5),
        people=_clean_list(data.get("people"), 8, names=True),
        kind=kind,
    )


if __name__ == "__main__":
    import glob
    import os
    import sys
    import time

    paths = sorted(glob.glob(r"D:\omi\transcripts\*.json"))
    if not available():
        print("ollama is not answering on 127.0.0.1:11434", file=sys.stderr)
        sys.exit(1)

    limit = int(sys.argv[1]) if len(sys.argv) > 1 else 10
    for p in paths[:limit]:
        d = json.load(open(p, encoding="utf-8"))
        t0 = time.time()
        s = summarize(d["text"])
        print(f"\n{os.path.basename(p)}  ({time.time() - t0:.1f}s)  "
              f"[{s.kind}{'' if s.is_speech else '  <- not a voice note'}]")
        print(f"  raw:     {d['text'][:110]}")
        print(f"  title:   {s.title}")
        print(f"  summary: {s.summary}")
        print(f"  topics:  {s.topics}")
        if s.people:
            print(f"  people:  {s.people}")
