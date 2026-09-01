#!/usr/bin/env python3
"""Codex CLI notify hook: stage the assistant's reply for the pill.

Codex invokes this with one argument: a JSON payload like
  {"type": "agent-turn-complete", "last-assistant-message": "...", ...}

Add to ~/.codex/config.toml:
  notify = ["<repo>/kokoro/codex_notify.py"]

If something else already occupies your notify slot, preserve it by
creating notify_forward.json next to this script containing the original
argv, e.g.:
  ["/path/to/original-notifier", "turn-ended"]
Every event is forwarded to it (with the JSON payload appended) before
being staged.
"""
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.realpath(os.path.abspath(__file__)))
sys.path.insert(0, HERE)
from speak_response import clean_for_speech, stage  # noqa: E402

FORWARD_CONFIG = os.path.join(HERE, "notify_forward.json")


def forward(json_arg):
    try:
        with open(FORWARD_CONFIG) as f:
            argv = json.load(f)
    except (OSError, json.JSONDecodeError):
        return
    if not (isinstance(argv, list) and argv):
        return
    try:
        subprocess.Popen(
            argv + [json_arg],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
    except OSError:
        pass


def main():
    if len(sys.argv) < 2:
        return
    forward(sys.argv[1])
    try:
        payload = json.loads(sys.argv[1])
    except json.JSONDecodeError:
        return
    if payload.get("type") != "agent-turn-complete":
        return
    text = clean_for_speech(payload.get("last-assistant-message") or "")
    if text:
        stage(text)


if __name__ == "__main__":
    main()
