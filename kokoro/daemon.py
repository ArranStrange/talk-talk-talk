#!/usr/bin/env python3
"""Talk Talk Talk — Kokoro TTS daemon.

Loads the Kokoro model once and serves requests over a unix socket.
Playback is streamed in-process via sounddevice, which gives instant
pause/resume and a seekable cursor for rollback.

Protocol: one JSON object per connection, e.g.
  {"cmd": "say", "text": "...", "voice": "af_heart", "speed": 1.1, "lang": "en-us"}
  {"cmd": "stop"} | {"cmd": "pause"} | {"cmd": "resume"} | {"cmd": "toggle"}
  {"cmd": "back", "seconds": 10}
  {"cmd": "status"} | {"cmd": "quit"}
Reply: {"ok": true, "msg": "..."}

Started automatically by the ktts client when not already running.
Run under the project venv (ktts handles this).
"""
import json
import os
import re
import socket
import sys
import threading
import time

HERE = os.path.dirname(os.path.realpath(os.path.abspath(__file__)))
SOCK_PATH = os.path.join(HERE, "daemon.sock")
STATE_PATH = os.path.join(HERE, "state")
WORD_PATH = os.path.join(HERE, "word")


def set_word(word):
    """Publish the currently-spoken word for the RSVP drawer."""
    try:
        with open(WORD_PATH + ".tmp", "w") as f:
            f.write(word)
        os.replace(WORD_PATH + ".tmp", WORD_PATH)
    except OSError:
        pass


def find_espeak():
    """Locate Homebrew's espeak-ng (Apple Silicon or Intel prefix)."""
    for prefix in ("/opt/homebrew", "/usr/local"):
        lib = os.path.join(prefix, "lib", "libespeak-ng.dylib")
        data = os.path.join(prefix, "share", "espeak-ng-data")
        if os.path.exists(lib) and os.path.exists(data):
            return lib, data
    lib = os.environ.get("TTT_ESPEAK_LIB")
    data = os.environ.get("TTT_ESPEAK_DATA")
    if lib and data:
        return lib, data
    sys.exit("espeak-ng not found: brew install espeak-ng "
             "(or set TTT_ESPEAK_LIB / TTT_ESPEAK_DATA)")


def set_state(state):
    """Publish daemon state for UI watchers (the Hammerspoon pill).

    Always writes (no dedupe): the editor hooks and the pill also write
    this file, so the daemon's idea of the last state can go stale.
    """
    try:
        with open(STATE_PATH + ".tmp", "w") as f:
            f.write(state)
        os.replace(STATE_PATH + ".tmp", STATE_PATH)
    except OSError:
        pass


set_state("loading")

import numpy as np
import sounddevice as sd
from kokoro_onnx import Kokoro, EspeakConfig

SR = 24000
START_BUFFER = SR * 2       # buffer 2s of audio before playback begins
RESUME_BUFFER = SR * 3 // 2 # after running dry, rebuild 1.5s before resuming

ESPEAK_LIB, ESPEAK_DATA = find_espeak()
kokoro = Kokoro(
    os.path.join(HERE, "kokoro-v1.0.onnx"),
    os.path.join(HERE, "voices-v1.0.bin"),
    espeak_config=EspeakConfig(lib_path=ESPEAK_LIB, data_path=ESPEAK_DATA),
)
# Warm up the graph so the first real request is fast too.
kokoro.create("Ready.", voice="af_heart", lang="en-us")
set_state("idle")

lock = threading.Lock()
generation = 0
# Preallocated audio buffer (10 min; grows if ever needed). Writes are
# in-place slice copies so the lock is only held briefly — concatenating
# under the lock caused audio-callback underruns.
buffer = np.zeros(SR * 600, dtype=np.float32)
buf_len = 0                             # samples written so far
cursor = 0                              # next sample to play
synth_done = True
paused = False
say_active = False
playing_started = False
stream = None
timeline = []                           # [(sample_start, word)] for RSVP


def split_chunks(text, max_len=300, first_max_len=100):
    text = text.strip()
    # If the very first sentence is long, break it at a comma so playback
    # can start on the first clause instead of waiting for the whole sentence.
    first_sentence = re.split(r"(?<=[.!?;:])\s+", text, maxsplit=1)[0]
    if len(first_sentence) > first_max_len:
        m = re.match(r"(.{30,%d}?,)\s+" % first_max_len, text)
        if m:
            return [m.group(1)] + split_chunks(text[m.end():], max_len, max_len)
    sentences = re.split(r"(?<=[.!?;:])\s+", text)
    chunks, cur = [], ""
    for s in sentences:
        limit = first_max_len if not chunks else max_len
        if cur and len(cur) + len(s) + 1 > limit:
            chunks.append(cur)
            cur = s
        else:
            cur = f"{cur} {s}".strip()
    if cur:
        chunks.append(cur)
    return chunks


FADE = int(0.015 * SR)      # 15ms edge fade per chunk: kills boundary clicks
CHUNK_GAP = int(0.12 * SR)  # short natural pause between joined chunks


def smooth_edges(samples):
    """Fade a chunk's head and tail so joins are click-free."""
    n = len(samples)
    f = min(FADE, n // 4)
    if f > 0:
        ramp = np.linspace(0.0, 1.0, f, dtype=np.float32)
        samples[:f] *= ramp
        samples[-f:] *= ramp[::-1]
    return samples


def word_weights(words):
    """Rough relative duration per word: syllable-ish count plus a pause
    bonus for trailing punctuation. Good to about a quarter second, and
    resynced at every chunk boundary so error never accumulates."""
    weights = []
    for w in words:
        vowel_groups = len(re.findall(r"[aeiouyAEIOUY]+", w))
        weight = float(max(1, vowel_groups))
        if re.search(r"[.,!?;:]$", w):
            weight += 0.4
        weights.append(weight)
    return weights


def build_timeline(chunk_text, start_sample, n_samples, lead_gap):
    """Distribute a chunk's samples across its words, proportional to
    estimated duration. Returns [(sample_start, word)]."""
    words = chunk_text.split()
    if not words:
        return []
    weights = word_weights(words)
    total = sum(weights)
    speech_start = start_sample + lead_gap
    speech_samples = max(1, n_samples - lead_gap)
    entries, acc = [], 0.0
    for word, weight in zip(words, weights):
        entries.append((int(speech_start + speech_samples * acc / total), word))
        acc += weight
    return entries


def synth_worker(gen, text, voice, speed, lang):
    global buffer, buf_len, synth_done, timeline
    first = True
    for chunk in split_chunks(text):
        with lock:
            if generation != gen:
                return
        try:
            samples, _ = kokoro.create(chunk, voice=voice, speed=speed, lang=lang)
        except Exception:
            continue
        samples = smooth_edges(np.asarray(samples, dtype=np.float32))
        lead_gap = 0
        if not first:
            lead_gap = CHUNK_GAP
            samples = np.concatenate(
                [np.zeros(CHUNK_GAP, dtype=np.float32), samples])
        first = False
        n = len(samples)
        # grow (rare): build the bigger array outside the lock
        if buf_len + n > len(buffer):
            new = np.zeros(max(len(buffer) * 2, buf_len + n), dtype=np.float32)
            with lock:
                if generation != gen:
                    return
                new[:buf_len] = buffer[:buf_len]
                buffer = new
        with lock:
            if generation != gen:
                return
            buffer[buf_len:buf_len + n] = samples
            timeline.extend(build_timeline(chunk, buf_len, n, lead_gap))
            buf_len += n
    with lock:
        if generation == gen:
            synth_done = True


def make_callback(gen):
    starved = [False]  # once dry, wait for RESUME_BUFFER before resuming

    def callback(outdata, frames, time_info, status):
        global cursor
        if status:
            print(f"audio status: {status}", flush=True)
        with lock:
            if generation != gen or paused:
                outdata.fill(0)
                return
            avail = buf_len - cursor
            if not synth_done:
                if starved[0]:
                    if avail >= RESUME_BUFFER:
                        starved[0] = False
                    else:
                        outdata.fill(0)
                        return
                elif avail < frames:
                    starved[0] = True
                    print("buffer dry: waiting for synthesis", flush=True)
                    outdata.fill(0)
                    return
            n = min(frames, max(avail, 0))
            if n > 0:
                outdata[:n, 0] = buffer[cursor:cursor + n]
                cursor += n
            if n < frames:
                outdata[n:, 0] = 0
            if synth_done and cursor >= buf_len:
                raise sd.CallbackStop
    return callback


def make_finished(gen):
    def finished():
        global say_active, playing_started
        done = False
        with lock:
            if generation == gen:
                say_active = False
                playing_started = False
                done = True
        if done:
            set_state("idle")
    return finished


def word_publisher(gen):
    """Map the playback cursor onto the word timeline and publish changes.

    Read-only with respect to playback, so RSVP can never disturb audio.
    """
    import bisect

    last = None
    while True:
        with lock:
            if generation != gen or not say_active:
                break
            starts = [t[0] for t in timeline]
            pos = cursor
            entries = timeline
            idx = bisect.bisect_right(starts, pos) - 1
            word = entries[idx][1] if idx >= 0 else None
        if word != last:
            last = word
            set_word(word or "")
        time.sleep(0.08)
    set_word("")


def player_worker(gen):
    """Wait for the first synthesized samples, then start the stream."""
    global stream, playing_started
    while True:
        with lock:
            if generation != gen:
                return
            # start once a comfortable buffer exists (or the text is fully
            # synthesized, whichever comes first)
            if buf_len >= START_BUFFER or (synth_done and buf_len > 0):
                break
            if synth_done and buf_len == 0:  # synthesis produced nothing
                return
        time.sleep(0.03)
    s = sd.OutputStream(
        samplerate=SR, channels=1, dtype="float32",
        blocksize=2048, latency="high",
        callback=make_callback(gen), finished_callback=make_finished(gen),
    )
    with lock:
        if generation != gen:
            s.close()
            return
        stream = s
        playing_started = True
    s.start()
    set_state("playing")


def stop_playback():
    global generation, buf_len, cursor, synth_done, paused, say_active
    global playing_started, stream, timeline
    with lock:
        generation += 1
        old_stream = stream
        stream = None
        buf_len = 0
        cursor = 0
        timeline = []
        synth_done = True
        paused = False
        say_active = False
        playing_started = False
    if old_stream is not None:
        try:
            old_stream.abort()
            old_stream.close()
        except Exception:
            pass
    set_state("idle")


def handle(req):
    global paused, say_active, synth_done, cursor
    cmd = req.get("cmd")
    if cmd == "say":
        text = (req.get("text") or "").strip()
        if not text:
            return {"ok": False, "msg": "no text"}
        stop_playback()
        with lock:
            gen = generation
            say_active = True
            synth_done = False
        set_state("synthesizing")
        threading.Thread(
            target=synth_worker,
            args=(gen, text, req.get("voice", "af_heart"),
                  float(req.get("speed", 1.1)), req.get("lang", "en-us")),
            daemon=True,
        ).start()
        threading.Thread(target=player_worker, args=(gen,), daemon=True).start()
        threading.Thread(target=word_publisher, args=(gen,), daemon=True).start()
        return {"ok": True, "msg": "speaking"}
    if cmd == "stop":
        stop_playback()
        return {"ok": True, "msg": "stopped"}
    if cmd in ("pause", "resume", "toggle"):
        with lock:
            if not (say_active and playing_started):
                return {"ok": False, "msg": "nothing playing"}
            if cmd == "toggle":
                cmd = "resume" if paused else "pause"
            paused = (cmd == "pause")
        set_state("paused" if paused else "playing")
        return {"ok": True, "msg": "paused" if paused else "resumed"}
    if cmd == "back":
        seconds = float(req.get("seconds", 10))
        with lock:
            if not say_active:
                return {"ok": False, "msg": "nothing playing"}
            cursor = max(0, cursor - int(seconds * SR))
        return {"ok": True, "msg": f"rolled back {seconds:g}s"}
    if cmd == "status":
        with lock:
            if paused:
                return {"ok": True, "msg": "paused"}
            if say_active and playing_started:
                return {"ok": True, "msg": "playing"}
            if say_active:
                return {"ok": True, "msg": "synthesizing"}
            return {"ok": True, "msg": "idle"}
    if cmd == "quit":
        stop_playback()

        def _exit_soon():
            time.sleep(0.3)  # let the reply reach the client first
            os._exit(0)

        threading.Thread(target=_exit_soon, daemon=True).start()
        return {"ok": True, "msg": "bye"}
    return {"ok": False, "msg": f"unknown command: {cmd}"}


def main():
    try:
        os.unlink(SOCK_PATH)
    except OSError:
        pass
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(SOCK_PATH)
    server.listen(8)
    while True:
        conn, _ = server.accept()
        try:
            data = conn.recv(1 << 20)
            reply = handle(json.loads(data.decode()))
            conn.sendall(json.dumps(reply).encode())
        except Exception as e:
            try:
                conn.sendall(json.dumps({"ok": False, "msg": str(e)}).encode())
            except OSError:
                pass
        finally:
            conn.close()


if __name__ == "__main__":
    main()
