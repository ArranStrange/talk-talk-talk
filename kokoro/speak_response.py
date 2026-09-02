#!/usr/bin/env python3
"""Claude Code Stop hook: stage the last assistant response for the pill.

Reads hook JSON from stdin, extracts the last assistant text from the
transcript, cleans it up for speech, then writes it to pending.txt and
sets the state file to "ready". The Hammerspoon pill shows "Claude
replied" with a play button (or speaks it immediately in auto mode).

Add to ~/.claude/settings.json:
  {"hooks": {"Stop": [{"hooks": [{"type": "command",
    "command": "<repo>/kokoro/speak_response.py", "async": true, "timeout": 30}]}]}}

Config via environment (set in the hook definition if desired):
  KOKORO_MAX   cap on characters staged (default 0 = read the whole reply)

Uses only the standard library.
"""
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.realpath(os.path.abspath(__file__)))


def last_assistant_text(transcript_path):
    text = None
    try:
        with open(transcript_path) as f:
            for line in f:
                try:
                    entry = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if entry.get("type") != "assistant":
                    continue
                content = entry.get("message", {}).get("content", [])
                parts = [b.get("text", "") for b in content
                         if isinstance(b, dict) and b.get("type") == "text"]
                if any(p.strip() for p in parts):
                    text = "\n".join(p for p in parts if p.strip())
    except OSError:
        return None
    return text


CODE_MAX_LINES = 4      # short snippets get read; longer ones announced
CODE_MAX_CHARS = 200
TABLE_MAX_ROWS = 12     # beyond this a table is announced, not recited


def speak_identifier(name):
    """Make code identifiers pronounceable.

    raiseThrottled() -> "raise Throttled"; MINIMUM_FREE -> "MINIMUM FREE".
    Applied only inside code spans, so ordinary prose is untouched.
    """
    name = re.sub(r"[;,]\s*$", "", name.strip())
    name = re.sub(r"\(\s*\)$", "", name)
    name = name.replace("::", " ").replace("_", " ").replace("/", " slash ")
    name = re.sub(r"(?<=[a-z0-9])(?=[A-Z])", " ", name)
    return re.sub(r"\s+", " ", name).strip()


def render_code(match):
    lang, body = (match.group(1) or "").strip(), match.group(2)
    lines = [l for l in body.strip().splitlines() if l.strip()]
    if not lines:
        return " "
    if len(lines) <= CODE_MAX_LINES and len(body) <= CODE_MAX_CHARS:
        spoken = "; ".join(speak_identifier(l) for l in lines)
        return f"\n\nCode. {spoken}.\n\n"
    what = f"{len(lines)} lines of {lang}" if lang else f"{len(lines)} lines"
    return f"\n\nCode block, {what}.\n\n"


def render_table(block):
    """Read a table as column-and-value pairs, one sentence per row."""
    rows = [r.strip() for r in block.strip().splitlines() if r.strip()]
    cells = []
    for r in rows:
        if re.fullmatch(r"\|?[\s:\-|]+\|?", r):
            continue  # the |---|---| separator
        cells.append([c.strip() for c in r.strip().strip("|").split("|")])
    if not cells:
        return " "
    header, body = cells[0], cells[1:]
    if not body:
        return "\n\n" + ", ".join(c for c in header if c) + ".\n\n"
    if len(body) > TABLE_MAX_ROWS:
        return f"\n\nTable, {len(body)} rows, not read out.\n\n"
    out = []
    for row in body:
        pairs = []
        for i, val in enumerate(row):
            if not val:
                continue
            name = header[i].strip() if i < len(header) else ""
            pairs.append(f"{name}: {val}" if name else val)
        if pairs:
            out.append(", ".join(pairs) + ".")
    return "\n\n" + " ".join(out) + "\n\n"


def clean_for_speech(text):
    """Turn markdown into something worth listening to.

    Structure is converted rather than deleted: headings and paragraphs end
    as their own sentence so the daemon gives them a pause, table rows are
    read as column-and-value pairs, and short code is spoken while long code
    is announced by size.
    """
    # fenced code first, before any other rule can touch its contents
    text = re.sub(r"```([^\n]*)\n(.*?)```", render_code, text, flags=re.DOTALL)
    # contiguous runs of pipe-delimited lines are a table
    text = re.sub(r"(?:^[ \t]*\|.*\|[ \t]*\n?)+",
                  lambda m: render_table(m.group(0)), text, flags=re.MULTILINE)
    # inline code: pronounceable, not literal
    text = re.sub(r"`([^`\n]+)`", lambda m: speak_identifier(m.group(1)), text)
    # links keep their label; bare URLs collapse to the site
    text = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", text)
    text = re.sub(r"https?://([^/\s]+)\S*", r"link to \1", text)
    # headings become a sentence of their own, with a paragraph break after
    text = re.sub(r"^[ \t]*#{1,6}[ \t]*(.+?)[ \t]*$",
                  lambda m: "\n\n" + m.group(1).rstrip(" .:") + ".\n\n",
                  text, flags=re.MULTILINE)
    text = re.sub(r"\*\*?|__?", "", text)          # emphasis markers
    text = re.sub(r"^[ \t]*>[ \t]?", "", text, flags=re.MULTILINE)  # quotes
    text = re.sub(r"^[ \t]*[-*_]{3,}[ \t]*$", "", text, flags=re.MULTILINE)

    # list items end as sentences, so each one earns its own pause
    def list_item(m):
        body = m.group(1).strip()
        if body and body[-1] not in ".!?:;":
            body += "."
        return body
    text = re.sub(r"^[ \t]*(?:[-*+]|\d+[.)])[ \t]+(.*)$", list_item,
                  text, flags=re.MULTILINE)

    # whitespace: keep paragraph breaks, flatten everything else
    text = re.sub(r"[ \t]+", " ", text)
    text = re.sub(r"\n{3,}", "\n\n", text)
    text = re.sub(r"(?<!\n)\n(?!\n)", " ", text)
    text = re.sub(r" +", " ", text)
    return text.strip()


def maybe_summarise(text):
    """TLDR mode: replace the reply with a summary before staging it.

    Off unless "tldr_replies" is set in config.json (the menu bar writes it).
    Runs here rather than in the UI because the hook is already async, so a
    slow provider delays only the spoken summary, never the agent.
    """
    try:
        with open(os.path.join(HERE, "config.json")) as f:
            cfg = json.load(f)
    except (OSError, json.JSONDecodeError):
        return text
    if not cfg.get("tldr_replies"):
        return text
    # Same threshold tldr.py uses, checked here too so a short reply does
    # not even spawn the process.
    if len(text.split()) < int(cfg.get("tldr_min_words") or 70):
        return text
    # Surface the wait: a provider can take tens of seconds, and without
    # this the pill stays blank and the delay looks like nothing happening.
    try:
        tmp = os.path.join(HERE, "state.tmp")
        with open(tmp, "w") as f:
            f.write("summarising")
        os.replace(tmp, os.path.join(HERE, "state"))
    except OSError:
        pass
    try:
        out = subprocess.run(
            [os.path.join(HERE, "tldr.py")],
            input=text, capture_output=True, text=True, timeout=180)
        summary = out.stdout.strip()
        if out.returncode == 0 and summary:
            return summary
    except (OSError, subprocess.SubprocessError):
        pass
    return text  # any failure falls back to reading the full reply


def stage(text):
    """Write cleaned text to pending.txt and flag state=ready for the pill.

    No length cap by default: the daemon synthesizes chunk by chunk and
    streams, so a long reply costs nothing but time. Set KOKORO_MAX to a
    character count to cap it.
    """
    text = maybe_summarise(text)
    max_chars = int(os.environ.get("KOKORO_MAX", "0"))
    if max_chars and len(text) > max_chars:
        text = text[:max_chars].rsplit(" ", 1)[0] + " ... response truncated."
    with open(os.path.join(HERE, "pending.txt"), "w") as f:
        f.write(text)
    try:  # a stale word must not linger under a new reply
        open(os.path.join(HERE, "word"), "w").close()
    except OSError:
        pass
    state_tmp = os.path.join(HERE, "state.tmp")
    with open(state_tmp, "w") as f:
        f.write("ready")
    os.replace(state_tmp, os.path.join(HERE, "state"))


def main():
    try:
        payload = json.load(sys.stdin)
    except json.JSONDecodeError:
        return
    transcript = payload.get("transcript_path")
    if not transcript:
        return
    text = last_assistant_text(transcript)
    if not text:
        return
    text = clean_for_speech(text)
    if not text:
        return
    stage(text)


if __name__ == "__main__":
    main()
