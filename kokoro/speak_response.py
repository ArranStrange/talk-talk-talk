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
  KOKORO_MAX   max characters staged (default 1500)

Uses only the standard library.
"""
import json
import os
import re
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


def stage(text):
    """Write cleaned text to pending.txt and flag state=ready for the pill."""
    max_chars = int(os.environ.get("KOKORO_MAX", "1500"))
    if len(text) > max_chars:
        text = text[:max_chars].rsplit(" ", 1)[0] + " ... response truncated."
    with open(os.path.join(HERE, "pending.txt"), "w") as f:
        f.write(text)
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
