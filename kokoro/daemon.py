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


def _cfg_value(key, default):
    """One value from config.json, or the default. The daemon otherwise
    receives its settings in each request; this is for tuning knobs."""
    try:
        with open(os.path.join(HERE, "config.json")) as f:
            v = json.load(f).get(key)
        return default if v is None else v
    except (OSError, ValueError):
        return default


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
# Playback starts as soon as the audio in hand covers rendering the NEXT
# chunk (estimated from how long the ones so far took), with a margin. The
# cap is the most we ever wait: it was the fixed gate before, and the log
# showed 4-13 s buffered at start on a machine rendering at 1.3-2.9x
# realtime, which was pure waiting.
START_CAP = SR * 7 // 2      # never wait for more than 3.5 s of audio
START_MARGIN = 1.25          # cushion >= 1.25x the next chunk's render time
START_FLOOR = SR // 2        # ...and never less than 0.5 s
RESUME_BUFFER = SR * 2       # after running dry, rebuild 2 s before resuming

# The device buffer must outlast the writer thread's worst wake-up. Measured
# on an M4 Pro while synthesising: the writer wakes up to ~230 ms late (the
# GIL, held by the synthesiser's Python-side work; the same with 4, 6 or 8
# threads), and latency="high" bought only 119 ms of buffer. Hence one
# underflow every couple of seconds on long reads. Requesting 0.13 s gave
# 471 ms here; the achieved figure is checked and the request raised if a
# device comes up short. Cost: after a pause, up to that much already-queued
# audio still plays out.
STREAM_LATENCY = 0.13
STREAM_MIN_BUFFER = 0.35     # seconds actually achieved, or ask again larger

# Read-along shows each word this far BEFORE it is heard. Readers track
# better when the word is already there as the sound starts; a word that
# appears after its onset reads as late. Overridable: rsvp_lead_ms in config.
RSVP_LEAD_MS = 120

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
streams_open = 0            # live PortAudio streams; must be 0 to re-init
# RSVP word timeline lives under its OWN lock: the audio callback must
# never wait on read-along bookkeeping.
tl_lock = threading.Lock()
synth_lock = threading.Lock()  # one model call at a time, see synth_worker
# Per-utterance figures the start gate plans with. Mutated under `lock`.
plan = {"chars": [], "rate": None, "rchars": 0, "rsecs": 0.0, "say_t0": 0.0,
        "dev_lag": 0,   # samples handed to the device but not yet heard
        "align": False, # refine word timing with Parakeet (read-along is on)
        "lead": 0}      # show each word this many samples early
timeline = []                           # [(sample_start, word)]
timeline_starts = []                    # sample_start only, for bisect


# Chunks must be small enough that synthesizing the NEXT one takes less
# time than playing the cushion we already hold. At ~3x realtime a 300ch
# chunk is ~18s of audio needing ~6s to render — far longer than the ~3.5s
# cushion, so playback reliably starved a few seconds in and then, once
# that huge chunk landed, never starved again. That was the "rough at the
# start, then it settles" symptom.
def split_sentences(text, limits):
    """Greedy sentence grouping under a per-position length limit.

    limits[i] caps chunk i; the last entry applies from then on. A short
    opening chunk starts playback early, a medium second one keeps the
    cushion ahead of the third, and full-size chunks follow.
    """
    text = text.strip()
    if not text:
        return []
    first_limit = limits[0]
    rest = limits[1:] or limits
    first_sentence = re.split(r"(?<=[.!?;:])\s+", text, maxsplit=1)[0]
    if len(first_sentence) > first_limit and first_limit > 30:
        # break a long opening sentence at a comma...
        m = re.match(r"(.{30,%d}?,)\s+" % first_limit, text)
        if m:
            return [m.group(1)] + split_sentences(text[m.end():], rest)
        # ...or, with no comma to hand, at the last word that fits, so one
        # long unpunctuated sentence cannot hold up the start
        cut = text.rfind(" ", 30, first_limit + 1)
        if cut > 30:
            return [text[:cut]] + split_sentences(text[cut + 1:], rest)
    sentences = re.split(r"(?<=[.!?;:])\s+", text)
    chunks, cur = [], ""
    for s in sentences:
        limit = limits[min(len(chunks), len(limits) - 1)]
        if cur and len(cur) + len(s) + 1 > limit:
            chunks.append(cur)
            cur = s
        else:
            cur = f"{cur} {s}".strip()
    if cur:
        chunks.append(cur)
    return chunks


# Opening chunk, then a medium one, then max_len. Measured here: 50 chars is
# ~1 s to render (~2.7 s of audio), so speech begins about a second after
# the request instead of after a 100-char chunk plus a 3.5 s bank.
FIRST_LIMITS = (50, 90)


def split_chunks(text, max_len=140, first_limits=FIRST_LIMITS):
    """Return [(chunk, lead_gap_samples)].

    Blank-line boundaries in the cleaned text mark headings, paragraphs and
    code/table blocks. Those get a longer pause than a plain sentence break,
    which is what makes a structured document navigable by ear.
    """
    out = []
    paragraphs = [p for p in re.split(r"\n\s*\n", text) if p.strip()]
    for para in paragraphs:
        # the ramp is by chunk count across the whole text, so a one-line
        # heading does not spend it
        limits = list(first_limits[len(out):]) + [max_len]
        for i, piece in enumerate(split_sentences(para, limits)):
            if not out:
                gap = 0
            else:
                gap = PARA_GAP if i == 0 else CHUNK_GAP
            out.append((piece, gap))
    return out


FADE = int(0.015 * SR)      # 15ms edge fade per chunk: kills boundary clicks
CHUNK_GAP = int(0.12 * SR)  # between sentences
PARA_GAP = int(0.42 * SR)   # after a heading, paragraph or block


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


def word_weights(words, lang="en-us"):
    """Relative duration per word for the heuristic timeline.

    Phoneme count from the same espeak-ng phonemiser Kokoro uses, so "SFG20"
    (spoken "S F G twenty") weighs what it costs to say rather than the one
    vowel group the old regex found. Measured against Parakeet on the same
    audio: 90th-percentile error 334 ms with vowel groups, 173 ms with
    phonemes. This is the fallback and the first ~180 ms of a chunk; with
    read-along on, refine_timeline() replaces it with aligned onsets.
    """
    weights = []
    for w in words:
        weight = None
        try:
            bare = re.sub(r"[^A-Za-z0-9']", " ", w).strip()
            if bare:
                ph = kokoro.tokenizer.phonemize(bare, lang)
                weight = float(len(re.sub(r"\s", "", ph)))
        except Exception:
            weight = None
        if not weight:
            weight = float(max(1, len(re.findall(r"[aeiouyAEIOUY]+", w))))
        if re.search(r"[.,!?;:]$", w):
            weight += 3.0        # a pause, in phoneme-sized units
        weights.append(max(1.0, weight))
    return weights


def build_timeline(chunk_text, start_sample, n_samples, lead_gap, lang="en-us"):
    """Distribute a chunk's samples across its words, proportional to
    estimated duration. Returns [(sample_start, word)]. A long lead gap
    (a paragraph break) gets a blank entry so the drawer empties during the
    pause instead of holding the previous sentence's last word."""
    words = chunk_text.split()
    if not words:
        return []
    weights = word_weights(words, lang)
    total = sum(weights)
    speech_start = start_sample + lead_gap
    speech_samples = max(1, n_samples - lead_gap)
    entries, acc = [], 0.0
    if lead_gap >= SR // 4:
        entries.append((start_sample, ""))
    for word, weight in zip(words, weights):
        entries.append((int(speech_start + speech_samples * acc / total), word))
        acc += weight
    return entries


def synth_worker(gen, text, voice, speed, lang):
    global buffer, buf_len, synth_done, chunks_done
    chunks = split_chunks(text)
    with lock:
        plan["chars"] = [len(c) for c, _ in chunks]   # what the gate has to plan for
    for chunk, gap in chunks:
        with lock:
            if generation != gen:
                print(f"utterance replaced after {chunks_done} chunks", flush=True)
                return
        try:
            with synth_lock:
                if generation != gen:
                    return
                t_render = time.time()
                samples, _ = kokoro.create(
                    chunk, voice=voice, speed=speed, lang=lang)
                t_render = time.time() - t_render
        except Exception as e:
            # never silent: a chunk that will not synthesize is the
            # difference between a full reading and a truncated one
            print(f"synth failed on {chunk[:60]!r}: {e}", flush=True)
            continue
        samples = smooth_edges(np.asarray(samples, dtype=np.float32))
        lead_gap = gap
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
        # work must not happen while the writer may be waiting.
        entries = build_timeline(chunk, buf_len, n, lead_gap, lang)
        with lock:
            if generation != gen:
                return
            if lead_gap:
                buffer[buf_len:buf_len + lead_gap] = 0
            buffer[buf_len + lead_gap:buf_len + n] = samples
            buf_len += n
            # Under the lock, so the gate never sees the audio without the
            # count (it used to be incremented after the lock was released).
            chunks_done += 1
            plan["rchars"] += len(chunk)
            plan["rsecs"] += t_render
            # Per-call overhead swamps a tiny chunk (a heading), so its
            # rate would say the machine is slow and the gate would wait
            # for the cap. Only trust the rate once 25 chars have rendered.
            plan["rate"] = (plan["rchars"] / plan["rsecs"]
                            if plan["rsecs"] > 0 and plan["rchars"] >= 25 else None)
        with tl_lock:
            timeline.extend(entries)
            timeline_starts.extend(e[0] for e in entries)
        if plan["align"]:
            # The heuristic timeline is in place immediately, so nothing waits
            # on this. The alignment worker refines it when playback can
            # afford the competition — see align_worker().
            align_queue.append((gen, chunk, samples, buf_len - n + lead_gap, entries))
    with lock:
        if generation == gen:
            synth_done = True


# Alignment must not compete with synthesis while playback is tight: measured
# with alignment running alongside, Kokoro dropped below realtime and the
# buffer ran dry ("only reads one sentence, then freezes"). One worker, and
# it waits until the audio in hand comfortably exceeds what an alignment
# pass costs, or synthesis is finished.
align_queue = []
ALIGN_MIN_CUSHION = SR * 3        # 3 s banked before aligning while synthesising


def align_worker():
    import dictate
    while True:
        if not align_queue:
            time.sleep(0.05)
            continue
        with lock:
            cushion = buf_len - cursor
            done = synth_done
            gen_now = generation
        job = align_queue[0]
        if job[0] != gen_now:
            align_queue.pop(0)             # stale utterance
            continue
        if not done and cushion < ALIGN_MIN_CUSHION:
            time.sleep(0.05)
            continue
        eng = dictate.engine()
        if not eng.transcriber_loaded:
            # Loading is heavy (2-3 s of disk and CPU). Never do it under a
            # live synthesis: this chunk keeps its heuristic timing. Once
            # synthesis is finished, load so the next utterance has it.
            if done:
                try:
                    eng.warm(need_llm=False)
                except Exception as e:
                    print(f"read-along: aligner load failed: {str(e)[:120]}", flush=True)
                align_queue.clear()
            else:
                align_queue.pop(0)        # drop this one; later chunks re-check
            continue
        align_queue.pop(0)
        refine_timeline(*job)


threading.Thread(target=align_worker, daemon=True).start()


def refine_timeline(gen, chunk, samples, speech_start, entries):
    """Replace a chunk's heuristic word starts with aligned ones.

    Measured against Parakeet on the same audio, the vowel-group heuristic
    is off by a mean of 122 ms and up to half a second; the alignment
    itself is within a frame (~80 ms). Words Parakeet could not match
    (numbers it spelled out, a mis-hearing that changed the count) are
    interpolated between their aligned neighbours.
    """
    if entries and entries[0][1] == "":
        entries = entries[1:]                 # the paragraph-gap blank stays as is
    if not entries:
        return
    try:
        import dictate
        words = [w for _, w in entries]
        starts = dictate.engine().align_words(samples, words, load=False)
    except Exception as e:
        print(f"read-along alignment skipped: {str(e).splitlines()[0][:120]}", flush=True)
        return
    if not starts or all(s is None for s in starts):
        return
    # interpolate the gaps, and pin the first word to the chunk's onset
    n = len(starts)
    if starts[0] is None:
        starts[0] = 0.0
    known = [i for i, s in enumerate(starts) if s is not None]
    for a, b in zip(known, known[1:]):
        for i in range(a + 1, b):
            starts[i] = starts[a] + (starts[b] - starts[a]) * (i - a) / (b - a)
    tail = known[-1]
    if tail < n - 1:                      # after the last aligned word: spread evenly
        per = max(0.0, (len(samples) / SR - starts[tail])) / (n - tail)
        for i in range(tail + 1, n):
            starts[i] = starts[tail] + per * (i - tail)
    new_entries = [(speech_start + int(s * SR), w) for s, w in zip(starts, words)]
    # keep the sequence monotonic even if two onsets came back equal
    for i in range(1, n):
        if new_entries[i][0] <= new_entries[i - 1][0]:
            new_entries[i] = (new_entries[i - 1][0] + 1, new_entries[i][1])
    with lock:
        if generation != gen:
            return
    with tl_lock:
        first = entries[0][0]
        try:
            i0 = timeline.index(entries[0])
        except ValueError:
            return                        # utterance replaced under us
        i1 = i0 + n
        if timeline[i0:i1] != entries:
            return
        timeline[i0:i1] = new_entries
        timeline_starts[i0:i1] = [e[0] for e in new_entries]


def start_threshold_locked():
    """Samples that must be banked before playback may begin. Under lock.

    Enough to cover rendering the next chunk at the rate seen so far, with
    a margin; never below START_FLOOR, never above START_CAP.
    """
    chars, rate = plan["chars"], plan["rate"]
    if chunks_done == 0:
        return START_CAP                 # nothing finished yet
    if chunks_done >= len(chars):
        return START_FLOOR               # everything is already rendered
    if not rate:
        return START_CAP
    need = int(chars[chunks_done] / rate * START_MARGIN * SR)
    return max(START_FLOOR, min(START_CAP, need))


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
            pos = max(0, cursor - plan["dev_lag"] + plan["lead"])
        with tl_lock:
            starts, entries = timeline_starts, timeline
        # bisect outside both locks: lists are append-only within a
        # generation, so a concurrent append can only add later words
        idx = bisect.bisect_right(starts, pos) - 1
        word = entries[idx][1] if 0 <= idx < len(entries) else None
        if word != last:
            last = word
            set_word(word or "")
        time.sleep(0.04)                  # half the old 80 ms; a word is ~250 ms
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
    """Open the CURRENT default output device, whatever it is now.

    PortAudio snapshots the device list when it initialises, and this daemon
    is long-lived: without re-initialising, a daemon started before you put
    your headphones on keeps talking to the built-in speakers forever, and
    no amount of reconnecting moves it. So re-read the devices on every
    stream, then fall back through sample rates the device will accept,
    since headphones at 44.1 kHz will refuse the model's native 24 kHz
    (seen in the wild as PortAudio -9986 / AUHAL -50).
    """
    # Terminating PortAudio while a stream is open is undefined behaviour.
    # stream is cleared the moment an utterance is replaced, so it is not a
    # safe signal on its own: wait for the writer thread to actually close.
    for _ in range(40):
        with lock:
            if streams_open == 0:
                break
        time.sleep(0.025)
    try:
        sd._terminate()
        sd._initialize()
    except Exception as e:
        print(f"could not refresh audio devices: {e}", flush=True)
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
                                blocksize=0, latency=STREAM_LATENCY)
            if s.latency < STREAM_MIN_BUFFER:
                # this device rounded the request down; ask for more
                s.close()
                s = sd.OutputStream(samplerate=rate, channels=1, dtype="float32",
                                    blocksize=0,
                                    latency=max(STREAM_MIN_BUFFER, STREAM_LATENCY * 2))
            name = "?"
            try:
                name = sd.query_devices(kind="output")["name"]
            except Exception:
                pass
            print(f"audio out: {name} at {rate} Hz, device buffer {s.latency*1000:.0f} ms",
                  flush=True)
            return s, rate          # opened, not started: the caller starts it
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
    global stream, playing_started, say_active, cursor, streams_open

    # Open the device first, so its re-initialisation overlaps the first
    # chunk's render instead of following it. It is not started until there
    # is audio to feed it.
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
        # Known from the moment the stream exists; set here rather than after
        # start() so the word publisher never runs a poll with lag 0.
        plan["dev_lag"] = int(s.latency * SR)

    while True:  # wait for enough audio to start on
        with lock:
            if generation != gen:
                s.close()
                return
            if buf_len >= start_threshold_locked() or (synth_done and buf_len > 0):
                break
            if synth_done and buf_len == 0:  # synthesis produced nothing
                say_active = False
                playing_started = False
                set_state("idle")
                s.close()
                return
        time.sleep(0.03)

    with lock:
        streams_open += 1
        if generation != gen:
            streams_open -= 1
            s.close()
            return
        stream = s
        playing_started = True
        buffered = buf_len / SR
        first_chars = plan["chars"][0] if plan["chars"] else 0
        rate_chars = plan["rate"] or 0.0
        since_say = time.time() - plan["say_t0"] if plan["say_t0"] else 0.0
    s.start()
    print(f"playback started {since_say:.2f}s after the request with {buffered:.1f}s "
          f"buffered (first chunk {first_chars} chars, rendering {rate_chars:.0f} chars/s)",
          flush=True)
    set_state("playing")
    silence = np.zeros(BLOCK, dtype=np.float32)
    starved = False
    underflows = 0   # PortAudio ran dry mid-write
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
                # write() returns True if the device underflowed — the glitch
                # you actually hear, one level below the daemon's own buffer.
                if s.write(resample(silence if out is None else out, rate)):
                    underflows += 1
            except Exception as e:
                with lock:
                    replaced = (generation != gen)
                if not replaced:
                    # a genuine device failure, not just a newer utterance
                    print(f"audio write failed, stopping: {e}", flush=True)
                break
    finally:
        # One line per utterance so a rough-sounding session leaves a
        # record that can be read afterwards, without replaying anything.
        print(f"utterance ended: {underflows} PortAudio underflows over "
              f"{time.time()-_t0:.1f}s", flush=True)
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
        with lock:
            streams_open = max(0, streams_open - 1)
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
        plan.update(chars=[], rate=None, rchars=0, rsecs=0.0, say_t0=0.0, dev_lag=0,
                    align=False, lead=0)
        align_queue.clear()
        say_active = False
        playing_started = False
    if old_stream is not None:
        try:
            old_stream.abort()
            old_stream.close()   # must be closed before PortAudio re-inits
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
            plan["say_t0"] = time.time()
            plan["align"] = bool(req.get("align", False))
            plan["lead"] = int(SR * float(_cfg_value("rsvp_lead_ms", RSVP_LEAD_MS)) / 1000)
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
    # -- dictation ---------------------------------------------------------
    # Lives in dictate.py and loads its models on first use, so a machine
    # that only ever uses speech pays nothing for it.
    if cmd == "dictation_warm":
        import dictate
        # The app sends the frontmost app's name so the matching prompt
        # prefix is cached while the key is still held.
        threading.Thread(target=dictate.engine().warm,
                         kwargs={"context": str(req.get("context") or "")},
                         daemon=True).start()
        return {"ok": True, "msg": "warming"}
    if cmd == "align_warm":
        import dictate
        threading.Thread(target=dictate.engine().warm, kwargs={"need_llm": False},
                         daemon=True).start()
        return {"ok": True, "msg": "warming aligner"}
    if cmd == "dictation_unload":
        import dictate
        return {"ok": True, "msg": "unloaded" if dictate.engine().unload() else "not loaded"}
    if cmd == "transcribe":
        import dictate
        path = req.get("path") or ""
        if not os.path.isfile(path):
            return {"ok": False, "msg": "no recording at that path"}
        return dictate.engine().transcribe(
            path, cleanup=bool(req.get("cleanup", True)),
            context=str(req.get("context") or ""))
    return {"ok": False, "msg": f"unknown command: {cmd}"}


def _serve(conn):
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


def main():
    try:
        os.unlink(SOCK_PATH)
    except OSError:
        pass
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(SOCK_PATH)
    server.listen(8)
    # A thread per connection: transcription takes a second or so, and
    # every command already takes the locks it needs, so a stop or pause
    # must not queue behind it.
    while True:
        conn, _ = server.accept()
        threading.Thread(target=_serve, args=(conn,), daemon=True).start()


if __name__ == "__main__":
    main()
