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


def synth_worker(gen, text, voice, speed, lang):
    global buffer, buf_len, synth_done
    for chunk in split_chunks(text):
        with lock:
            if generation != gen:
                return
        try:
            samples, _ = kokoro.create(chunk, voice=voice, speed=speed, lang=lang)
        except Exception:
            continue
        samples = np.asarray(samples, dtype=np.float32)
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
            buf_len += n
    with lock:
        if generation == gen:
            synth_done = True


def make_callback(gen):
    def callback(outdata, frames, time_info, status):
        global cursor
        if status:
            print(f"audio status: {status}", flush=True)
        with lock:
            if generation != gen or paused:
                outdata.fill(0)
                return
            avail = buf_len - cursor
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


def player_worker(gen):
    """Wait for the first synthesized samples, then start the stream."""
    global stream, playing_started
    while True:
        with lock:
            if generation != gen:
                return
            if buf_len > 0:
                break
            if synth_done:  # synthesis produced nothing
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
    global playing_started, stream
    with lock:
        generation += 1
        old_stream = stream
        stream = None
        buf_len = 0
        cursor = 0
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
