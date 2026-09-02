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


def clean_for_speech(text):
    # drop fenced code blocks entirely
    text = re.sub(r"```.*?```", " (code omitted) ", text, flags=re.DOTALL)
    # inline code: keep the content, drop backticks
    text = re.sub(r"`([^`]*)`", r"\1", text)
    # markdown links: keep the label
    text = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", text)
    # headers, bold, italics, list bullets, tables
    text = re.sub(r"^#{1,6}\s*", "", text, flags=re.MULTILINE)
    text = re.sub(r"\*\*?|__?", "", text)
    text = re.sub(r"^\s*[-*+]\s+", "", text, flags=re.MULTILINE)
    text = re.sub(r"^\s*\|.*\|\s*$", "", text, flags=re.MULTILINE)
    # collapse whitespace
    text = re.sub(r"\s+", " ", text).strip()
    return text


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
    if len(text.split()) < 40:
        return text  # not worth summarising
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
