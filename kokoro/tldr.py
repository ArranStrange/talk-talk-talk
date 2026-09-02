#!/usr/bin/env python3
"""Summarise text read from stdin and print the summary to stdout.

Providers, chosen by "tldr_provider" in config.json:

  claude-cli   the installed `claude` CLI in headless mode. No API key and
               no per-call charge; it draws on your Claude subscription
               allowance instead. The default, because it needs no setup.
  anthropic    the Anthropic API directly. Needs a key. Fast and cheap.
  openai       the OpenAI API. Needs a key.
  extractive   no model at all: scores sentences by word frequency and
               returns the best few. Free, instant, offline, and it selects
               existing sentences rather than writing new prose.

API keys are read from the macOS Keychain, falling back to the environment.
This script never writes a key anywhere; see `ttt-set-key` for storing one.

Usage:  … | tldr.py [--provider X] [--model Y] [--sentences N]
"""
import argparse
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.realpath(os.path.abspath(__file__)))
CONFIG_PATH = os.path.join(HERE, "config.json")

KEYCHAIN_ACCOUNT = "talk-talk-talk"
KEYCHAIN_SERVICE = {"anthropic": "ttt-anthropic", "openai": "ttt-openai"}
ENV_VAR = {"anthropic": "ANTHROPIC_API_KEY", "openai": "OPENAI_API_KEY"}
DEFAULT_MODEL = {
    "anthropic": "claude-haiku-4-5-20251001",
    "openai": "gpt-4o-mini",
    "claude-cli": "haiku",
}


def config():
    try:
        with open(CONFIG_PATH) as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError):
        return {}


def api_key(provider):
    """Keychain first, then the environment. Never logged, never stored."""
    service = KEYCHAIN_SERVICE.get(provider)
    if service:
        try:
            out = subprocess.run(
                ["security", "find-generic-password",
                 "-a", KEYCHAIN_ACCOUNT, "-s", service, "-w"],
                capture_output=True, text=True, timeout=10)
            if out.returncode == 0 and out.stdout.strip():
                return out.stdout.strip()
        except (OSError, subprocess.SubprocessError):
            pass
    return os.environ.get(ENV_VAR.get(provider, ""), "").strip()


def prompt_for(text, sentences):
    return (f"Summarise the following in at most {sentences} short sentences. "
            "Plain prose, no preamble, no bullet points, no heading. "
            "Lead with the single most important point.\n\n" + text)


def via_claude_cli(text, model, sentences):
    cmd = ["claude", "-p", prompt_for(text, sentences)]
    if model:
        cmd[1:1] = ["--model", model]
    out = subprocess.run(cmd, capture_output=True, text=True,
                         timeout=120, stdin=subprocess.DEVNULL)
    if out.returncode != 0:
        raise RuntimeError((out.stderr or "claude CLI failed").strip()[:300])
    return out.stdout.strip()


def post_json(url, headers, payload, timeout=90):
    req = urllib.request.Request(
        url, data=json.dumps(payload).encode(),
        headers={"content-type": "application/json", **headers})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "replace")[:300]
        if "anthropic-workspace-id is required" in detail:
            raise RuntimeError(
                "this Anthropic key is identity-linked and needs a workspace "
                "id. Find it in console.anthropic.com > Settings > Workspaces "
                "(it looks like wrkspc_...) and set anthropic_workspace_id in "
                "config.json, or use the menu bar item.") from None
        raise RuntimeError(f"HTTP {e.code}: {detail}") from None
    except urllib.error.URLError as e:
        raise RuntimeError(f"network error: {e.reason}") from None


def via_anthropic(text, model, sentences):
    key = api_key("anthropic")
    if not key:
        raise RuntimeError("no Anthropic API key stored (see: ttt-set-key anthropic)")
    headers = {"x-api-key": key, "anthropic-version": "2023-06-01"}
    # Identity-linked keys must name the workspace the request acts in.
    # Not a secret, so it lives in config.json rather than the Keychain.
    workspace = (os.environ.get("ANTHROPIC_WORKSPACE_ID")
                 or config().get("anthropic_workspace_id") or "").strip()
    if workspace:
        headers["anthropic-workspace-id"] = workspace
    data = post_json(
        "https://api.anthropic.com/v1/messages",
        headers,
        {"model": model or DEFAULT_MODEL["anthropic"],
         "max_tokens": 400,
         "messages": [{"role": "user", "content": prompt_for(text, sentences)}]})
    parts = [b.get("text", "") for b in data.get("content", [])
             if b.get("type") == "text"]
    return "\n".join(p for p in parts if p).strip()


def via_openai(text, model, sentences):
    key = api_key("openai")
    if not key:
        raise RuntimeError("no OpenAI API key stored (see: ttt-set-key openai)")
    data = post_json(
        "https://api.openai.com/v1/chat/completions",
        {"authorization": f"Bearer {key}"},
        {"model": model or DEFAULT_MODEL["openai"],
         "max_completion_tokens": 400,
         "messages": [{"role": "user", "content": prompt_for(text, sentences)}]})
    choices = data.get("choices") or []
    if not choices:
        raise RuntimeError("no completion returned")
    return (choices[0].get("message", {}).get("content") or "").strip()


STOPWORDS = set("""a an and are as at be been but by for from had has have he her
his in is it its of on or that the their they this to was were which who will
with would you your we our i not no if then than so such can could may might
also more most other some only very just about into over after before""".split())


def via_extractive(text, model, sentences):
    """Frequency-scored sentence selection. No model, no network, no cost."""
    raw = re.split(r"(?<=[.!?])\s+", text.strip())
    raw = [s.strip() for s in raw if len(s.split()) >= 4]
    if len(raw) <= sentences:
        return " ".join(raw)
    freq = {}
    for word in re.findall(r"[a-z']+", text.lower()):
        if word not in STOPWORDS and len(word) > 2:
            freq[word] = freq.get(word, 0) + 1
    scored = []
    for i, s in enumerate(raw):
        words = re.findall(r"[a-z']+", s.lower())
        if not words:
            continue
        # mean word weight, so long sentences are not automatically favoured
        score = sum(freq.get(w, 0) for w in words) / len(words)
        if i == 0:
            score *= 1.3  # opening sentences usually carry the thesis
        scored.append((score, i, s))
    scored.sort(reverse=True)
    picked = sorted(scored[:sentences], key=lambda t: t[1])
    return " ".join(s for _, _, s in picked)


PROVIDERS = {
    "claude-cli": via_claude_cli,
    "anthropic": via_anthropic,
    "openai": via_openai,
    "extractive": via_extractive,
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--provider")
    ap.add_argument("--model")
    ap.add_argument("--sentences", type=int)
    args = ap.parse_args()

    cfg = config()
    provider = args.provider or cfg.get("tldr_provider") or "claude-cli"
    model = args.model or cfg.get("tldr_model") or DEFAULT_MODEL.get(provider)
    sentences = args.sentences or int(cfg.get("tldr_sentences") or 3)

    fn = PROVIDERS.get(provider)
    if not fn:
        sys.exit(f"unknown provider: {provider}")

    text = sys.stdin.read().strip()
    if not text:
        sys.exit("nothing to summarise")
    if len(text.split()) < 25:
        print(text)  # already short enough to be its own summary
        return

    try:
        summary = fn(text, model, sentences)
    except Exception as e:
        sys.exit(f"TLDR failed: {e}")
    if not summary:
        sys.exit("TLDR failed: empty summary")
    print(summary)


if __name__ == "__main__":
    main()
