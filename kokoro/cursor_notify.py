#!/usr/bin/env python3
"""Cursor hook: stage the agent's reply for the pill.

Cursor's `afterAgentResponse` hook receives JSON on stdin including the
assistant's final text:
  {"text": "<assistant final text>", ...}

Add to ~/.cursor/hooks.json (or <project>/.cursor/hooks.json):

  {
    "version": 1,
    "hooks": {
      "afterAgentResponse": [
        { "command": "<repo>/kokoro/cursor_notify.py" }
      ]
    }
  }

Note: in long agentic runs Cursor may emit several response blocks per
turn; each one replaces the staged text (last writer wins), which also
means auto-read mode speaks each block as it arrives.
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.realpath(os.path.abspath(__file__)))
sys.path.insert(0, HERE)
from speak_response import clean_for_speech, stage  # noqa: E402


def main():
    try:
        payload = json.load(sys.stdin)
    except json.JSONDecodeError:
        return
    text = clean_for_speech(payload.get("text") or "")
    if text:
        stage(text)


if __name__ == "__main__":
    main()
    # hooks may parse stdout as JSON; an empty object means "no opinion"
    print("{}")
