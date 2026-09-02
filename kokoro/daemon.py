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
    """Publish daemon state for UI watchers (Hammerspoon pill).

    Always writes (no dedupe): the Stop-hook and the pill also write this
    file, so the daemon's idea of the last state can go stale.
    """
    try:
        with open(STATE_PATH + ".tmp", "w") as f:
            f.write(state)
        os.replace(STATE_PATH + ".tmp", STATE_PATH)
    except OSError:
        pass


set_state("loading")

import numpy as np
import onnxruntime as ort
import sounddevice as sd
from kokoro_onnx import Kokoro, EspeakConfig


def synth_threads():
    """Performance cores, capped at 8. Measured on an M4 Pro: 8 threads
    gives ~3.2x realtime vs ~2.4x for onnxruntime's default, while 10+
    oversubscribes onto the efficiency cores and gets slower again."""
    env = os.environ.get("KOKORO_THREADS")
    if env and env.isdigit():
        return int(env)
    try:
        import subprocess
        out = subprocess.run(["sysctl", "-n", "hw.perflevel0.logicalcpu"],
                             capture_output=True, text=True).stdout.strip()
        cores = int(out)
    except (OSError, ValueError):
        cores = 8
    return max(4, min(8, cores))

SR = 24000
START_BUFFER = SR * 7 // 2  # bank 3.5s of audio before playback begins
RESUME_BUFFER = SR * 2      # after running dry, rebuild 2s before resuming
MIN_START = SR * 5 // 2     # ...but a finished chunk holding 2.5s is enough

ESPEAK_LIB, ESPEAK_DATA = find_espeak()
_opts = ort.SessionOptions()
_opts.intra_op_num_threads = synth_threads()
_opts.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
_session = ort.InferenceSession(
    os.path.join(HERE, "kokoro-v1.0.onnx"), _opts,
    providers=["CPUExecutionProvider"],
)
kokoro = Kokoro.from_session(
    _session,
    os.path.join(HERE, "voices-v1.0.bin"),
    espeak_config=EspeakConfig(lib_path=ESPEAK_LIB, data_path=ESPEAK_DATA),
)
# Warm up the graph so the first real request is fast too.
kokoro.create("Ready.", voice="af_heart", lang="en-us")
set_state("idle")

lock = threading.Lock()
generation = 0
# Preallocated ring-free audio buffer (10 min; grows if ever needed).
# Writes are in-place slice copies so the lock is only held briefly —
# np.concatenate under the lock caused audio-callback underruns.
buffer = np.zeros(SR * 600, dtype=np.float32)
buf_len = 0                             # samples written so far
cursor = 0                              # next sample to play
synth_done = True
chunks_done = 0                         # completed chunks this utterance
paused = False
say_active = False
playing_started = False
stream = None
# RSVP word timeline lives under its OWN lock: the audio callback must
# never wait on read-along bookkeeping.
tl_lock = threading.Lock()
synth_lock = threading.Lock()  # one model call at a time, see synth_worker
timeline = []                           # [(sample_start, word)]
timeline_starts = []                    # sample_start only, for bisect


# Chunks must be small enough that synthesizing the NEXT one takes less
# time than playing the cushion we already hold. At ~3x realtime a 300ch
# chunk is ~18s of audio needing ~6s to render — far longer than the ~3.5s
# cushion, so playback reliably starved a few seconds in and then, once
# that huge chunk landed, never starved again. That was the "rough at the
# start, then it settles" symptom.
def split_chunks(text, max_len=140, first_max_len=100):
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


_FADE_RAMP = np.linspace(0.0, 1.0, FADE, dtype=np.float32)


def smooth_edges(samples):
    """Fade a chunk's head and tail so joins are click-free.

    The ramp is precomputed: allocating one per chunk was a needless
    GIL-holding allocation on the synthesis thread.
    """
    n = len(samples)
    f = min(FADE, n // 4)
    if f > 8:  # a tiny chunk would be all ramp and no speech
        ramp = _FADE_RAMP[:f]
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
    global buffer, buf_len, synth_done, chunks_done
    first = True
    for chunk in split_chunks(text):
        with lock:
            if generation != gen:
                return
        try:
            with synth_lock:
                if generation != gen:
                    return
                samples, _ = kokoro.create(
                    chunk, voice=voice, speed=speed, lang=lang)
        except Exception:
            continue
        samples = smooth_edges(np.asarray(samples, dtype=np.float32))
        lead_gap = 0 if first else CHUNK_GAP
        first = False
        n = len(samples) + lead_gap
        # grow (rare): build the bigger array outside the lock
        if buf_len + n > len(buffer):
            new = np.zeros(max(len(buffer) * 2, buf_len + n), dtype=np.float32)
            with lock:
                if generation != gen:
                    return
                new[:buf_len] = buffer[:buf_len]
                buffer = new
        # Built before taking the audio lock — this thread is the only
        # writer of buf_len, so reading it here is safe, and the regex
        # work must not happen while the audio callback may be waiting.
        entries = build_timeline(chunk, buf_len, n, lead_gap)
        with lock:
            if generation != gen:
                return
            if lead_gap:
                buffer[buf_len:buf_len + lead_gap] = 0
            buffer[buf_len + lead_gap:buf_len + n] = samples
            buf_len += n
        with tl_lock:
            timeline.extend(entries)
            timeline_starts.extend(e[0] for e in entries)
        chunks_done += 1
    with lock:
        if generation == gen:
            synth_done = True


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
            pos = cursor
        with tl_lock:
            starts, entries = timeline_starts, timeline
        # bisect outside both locks: lists are append-only within a
        # generation, so a concurrent append can only add later words
        idx = bisect.bisect_right(starts, pos) - 1
        word = entries[idx][1] if 0 <= idx < len(entries) else None
        if word != last:
            last = word
            set_word(word or "")
        time.sleep(0.08)
    set_word("")


BLOCK = 2048  # samples per write (~85ms): pause/rollback granularity


def resample(block, dst_rate):
    """Linear resample a mono float32 block from SR to dst_rate."""
    if dst_rate == SR:
        return block
    n = max(1, int(round(len(block) * dst_rate / SR)))
    src_idx = np.linspace(0.0, len(block) - 1, n)
    return np.interp(src_idx, np.arange(len(block)), block).astype(np.float32)


def open_output_stream():
    """Open the device, tolerating a machine whose audio just changed.

    Joining a call, plugging in headphones or switching docks can make
    CoreAudio reject a stream at our native 24 kHz (seen in the wild as
    PortAudio -9986 / AUHAL -50). Fall back to whatever the current default
    device actually wants and resample into it, rather than going silent.
    """
    attempts = [SR]
    try:
        default = float(sd.query_devices(kind="output")["default_samplerate"])
        if int(default) != SR:
            attempts.append(int(default))
    except Exception:
        pass
    for rate in attempts + [48000, 44100]:
        if rate != attempts[0] and rate in attempts[:-1]:
            continue
        try:
            s = sd.OutputStream(samplerate=rate, channels=1, dtype="float32",
                                blocksize=0, latency="high")
            s.start()
            if rate != SR:
                print(f"audio device refused {SR} Hz; using {rate} Hz",
                      flush=True)
            return s, rate
        except Exception as e:
            print(f"audio open at {rate} Hz failed: {e}", flush=True)
    return None, SR


def player_worker(gen):
    """Feed the output stream with blocking writes from a normal thread.

    Deliberately NOT a PortAudio callback. A Python callback has to take
    the GIL to the beat of the audio clock, and the onnxruntime synthesis
    threads starve it — measured as 200ms gaps on an 85ms deadline, only
    ever while synthesis was still running, which is exactly when the
    audio sounded rough. sd.write() instead blocks in C with the GIL
    released, and PortAudio's own buffer covers any stall on this side.
    """
    global stream, playing_started, say_active, cursor

    while True:  # wait for enough audio to start on
        with lock:
            if generation != gen:
                return
            if (buf_len >= START_BUFFER
                    or (chunks_done >= 1 and buf_len >= MIN_START)
                    or (synth_done and buf_len > 0)):
                break
            if synth_done and buf_len == 0:  # synthesis produced nothing
                say_active = False
                playing_started = False
                set_state("idle")
                return
        time.sleep(0.03)

    s, rate = open_output_stream()
    if s is None:
        with lock:
            if generation == gen:
                say_active = False
                playing_started = False
        set_state("idle")
        print("playback aborted: no usable audio device", flush=True)
        return
    with lock:
        if generation != gen:
            s.close()
            return
        stream = s
        playing_started = True
        buffered = buf_len / SR
    print(f"playback started with {buffered:.1f}s buffered", flush=True)
    set_state("playing")

    silence = np.zeros(BLOCK, dtype=np.float32)
    starved = False
    _t0 = time.time()
    try:
        while True:
            out = None
            with lock:
                if generation != gen:
                    return
                if not paused:
                    avail = buf_len - cursor
                    if synth_done and avail <= 0:
                        break                       # spoken to the end
                    if not synth_done and starved and avail < RESUME_BUFFER:
                        pass                        # rebuilding the cushion
                    elif not synth_done and avail < BLOCK:
                        if not starved:
                            starved = True
                            print(f"buffer dry at t+{time.time()-_t0:.1f}s "
                                  f"(played {cursor/SR:.1f}s, have {buf_len/SR:.1f}s, "
                                  f"synth_done={synth_done})", flush=True)
                    else:
                        starved = False
                        n = min(BLOCK, avail)
                        if n > 0:
                            out = buffer[cursor:cursor + n].copy()
                            cursor += n
            try:
                s.write(resample(silence if out is None else out, rate))
            except Exception as e:
                # device pulled out from under us mid-sentence
                print(f"audio write failed, stopping: {e}", flush=True)
                break
    finally:
        done = False
        with lock:
            if generation == gen:
                stream = None
                say_active = False
                playing_started = False
                done = True
        try:
            s.stop()
            s.close()
        except Exception:
            pass
        if done:
            set_state("idle")


def stop_playback():
    global generation, buf_len, cursor, synth_done, paused, say_active
    global playing_started, stream, timeline, timeline_starts, chunks_done
    with tl_lock:
        timeline = []
        timeline_starts = []
    with lock:
        generation += 1
        old_stream = stream
        stream = None
        buf_len = 0
        cursor = 0
        chunks_done = 0
        synth_done = True
        paused = False
        say_active = False
        playing_started = False
    if old_stream is not None:
        try:
            old_stream.abort()
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
