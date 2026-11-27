"""Dictation engine: speech to text, then a small language model tidies it.

Two models, both open and both resident once loaded, run through MLX on
Apple Silicon or ONNX/llama.cpp elsewhere (dictate_backends.py):

  Parakeet TDT 0.6B v3 (NVIDIA, CC-BY-4.0) — transcription with
      punctuation and capitalisation built in.
  Qwen3 4B Instruct (Alibaba, Apache 2.0) — removes fillers and
      false starts, applies the personal dictionary, fixes what the
      transcriber got wrong. This step is what makes dictation feel like
      writing rather than a transcript.

Silero VAD (MIT) trims leading and trailing silence first, and tells us when
nothing was said at all, so an accidental tap of the key pastes nothing.

Models load on first use (or on `warm`, which the app sends when the key
goes down so loading overlaps with speaking) and unload after a period of
idleness so 3-4 GB is not held for a feature used a few times an hour.
"""
import gc
import os
import re
import sys
import threading
import time
import wave

import numpy as np

HERE = os.path.dirname(os.path.realpath(os.path.abspath(__file__)))
sys.path.insert(0, HERE)
import bf_paths          # noqa: E402
import dictate_backends  # noqa: E402

DEFAULT_IDLE_MINUTES = 10
DEFAULT_CLEANUP_MIN_WORDS = 4     # shorter than this is pasted as transcribed
SR = 16000


def _config():
    return bf_paths.load_config()


def _dictionary():
    try:
        with open(bf_paths.DICTIONARY, encoding="utf-8") as f:
            return [ln.strip() for ln in f if ln.strip() and not ln.startswith("#")]
    except OSError:
        return []


# --------------------------------------------------------------------------
# Voice activity: trim silence, detect "nothing said"
# --------------------------------------------------------------------------

class Vad:
    """Silero VAD v5 over 512-sample windows at 16 kHz.

    Falls back to an energy threshold if the model is missing, so dictation
    still works — it just trims less cleverly.
    """

    WINDOW = 512
    CONTEXT = 64

    def __init__(self):
        self.session = None
        try:
            import onnxruntime as ort
            opts = ort.SessionOptions()
            opts.inter_op_num_threads = 1
            opts.intra_op_num_threads = 1
            self.session = ort.InferenceSession(
                bf_paths.model("silero_vad.onnx"), opts,
                providers=["CPUExecutionProvider"])
        except Exception:
            self.session = None

    def speech_mask(self, samples):
        """Per-window speech probability > 0.5, as a boolean array."""
        n = len(samples) // self.WINDOW
        if self.session is None:
            # energy fallback: a window is speech if it is well above the
            # quietest 10% of windows
            frames = samples[:n * self.WINDOW].reshape(n, self.WINDOW)
            rms = np.sqrt((frames ** 2).mean(axis=1) + 1e-9)
            floor = np.percentile(rms, 10)
            return rms > max(floor * 4, 0.01)
        # Silero v5 wants each 512-sample window prefixed with the last 64
        # samples of the previous one (576 in). Without that context the
        # model returns near-zero everywhere: measured max 0.13 on clear
        # speech versus 1.0 with it.
        state = np.zeros((2, 1, 128), dtype=np.float32)
        context = np.zeros(self.CONTEXT, dtype=np.float32)
        sr = np.array(SR, dtype=np.int64)
        out = np.zeros(n, dtype=bool)
        for i in range(n):
            chunk = samples[i * self.WINDOW:(i + 1) * self.WINDOW].astype(np.float32)
            x = np.concatenate([context, chunk])[None, :]
            prob, state = self.session.run(
                None, {"input": x, "state": state, "sr": sr})
            out[i] = prob[0, 0] > 0.5
            context = chunk[-self.CONTEXT:]
        return out

    def trim(self, samples, pad_ms=250):
        """Return speech-only samples with padding, or None if none found."""
        if len(samples) < self.WINDOW * 4:
            return None
        mask = self.speech_mask(samples)
        idx = np.flatnonzero(mask)
        if len(idx) == 0:
            return None
        pad = int(SR * pad_ms / 1000)
        start = max(0, idx[0] * self.WINDOW - pad)
        end = min(len(samples), (idx[-1] + 1) * self.WINDOW + pad)
        return samples[start:end]


# --------------------------------------------------------------------------
# The engine
# --------------------------------------------------------------------------

class Engine:
    def __init__(self):
        self.lock = threading.Lock()
        self.backend = dictate_backends.choose(_config())
        self.vad = Vad()
        self._stt_warm = False
        self.last_used = 0.0
        self.load_lock = threading.Lock()
        # One generation at a time: a key-down primes the prompt cache while
        # the previous cleanup may still be running, and a llama.cpp context
        # is not safe to share between threads.
        self.llm_lock = threading.Lock()
        threading.Thread(target=self._idle_watch, daemon=True).start()
        print(f"dictation: using the {self.backend.name} backend", flush=True)

    # -- loading -----------------------------------------------------------

    def warm(self, need_llm=None, context=""):
        """Load whatever is not loaded. Safe to call repeatedly.

        The transcriber is required; the cleanup model is not. If it cannot
        load — not downloaded yet, out of memory, a broken cache — dictation
        still works and returns the raw transcript, rather than failing the
        whole thing over the optional half.
        """
        # A blocking lock, not a flag: the app warms on key-down and asks
        # for the transcript on key-up, and if the load is still running at
        # that point the transcript must wait for it, not be dropped.
        b = self.backend
        with self.load_lock:
            cfg = _config()
            if need_llm is None:
                need_llm = bool(cfg.get("dictation_cleanup", True))
            if not b.stt_loaded:
                b.load_stt(cfg)
            if not b.llm_loaded and need_llm:
                try:
                    b.load_llm(cfg)
                except Exception as e:
                    print(f"dictation: cleanup model unavailable, using raw "
                          f"transcripts: {str(e).splitlines()[0][:160]}", flush=True)
            # Warm-up: the first transcription and first generation after a
            # load each pay ~1 s of kernel compilation. Spend it now, while
            # the key is still held, rather than on the user's first sentence.
            if b.stt_loaded and not self._stt_warm:
                try:
                    b.transcribe(np.zeros(SR // 2, dtype=np.float32))
                    self._stt_warm = True
                except Exception:
                    pass
            if b.llm_loaded:
                try:
                    with self.llm_lock:
                        b.prime(self._system_rules(context))
                except Exception as e:
                    print(f"dictation: prefix cache failed: {e}", flush=True)
        self.last_used = time.time()

    def needs_download(self, need_llm=None):
        """True if the next load has to fetch models first: the first
        dictation on a new install. Quick and offline."""
        b = self.backend
        if need_llm is None:
            need_llm = bool(_config().get("dictation_cleanup", True))
        if b.stt_loaded and (b.llm_loaded or not need_llm):
            return False
        try:
            return not b.cached(_config(), need_llm)
        except Exception:
            return False

    @property
    def transcriber_loaded(self):
        return self.backend.stt_loaded

    def unload(self):
        with self.lock:
            had = self.backend.stt_loaded or self.backend.llm_loaded
            self.backend.unload()
            self._stt_warm = False
        if had:
            gc.collect()
            print("dictation: models unloaded", flush=True)
        return had

    def _idle_watch(self):
        while True:
            time.sleep(30)
            minutes = float(_config().get("dictation_idle_unload_min") or DEFAULT_IDLE_MINUTES)
            if minutes <= 0:
                continue
            if (self.backend.stt_loaded or self.backend.llm_loaded) and time.time() - self.last_used > minutes * 60:
                self.unload()

    # -- the pipeline ------------------------------------------------------

    def transcribe(self, path, cleanup=True, context=""):
        """Full pipeline for one recording. Returns a reply dict."""
        self.last_used = time.time()
        samples = self._read_wav(path)
        if samples is None:
            return {"ok": False, "msg": "could not read the recording"}

        trimmed = self.vad.trim(samples)
        if trimmed is None or len(trimmed) < SR * 0.3:
            return {"ok": False, "msg": "nothing was said"}

        try:
            self.warm(need_llm=cleanup, context=context)   # same prefix the cleanup will use
        except Exception as e:
            return {"ok": False, "msg": f"transcriber failed to load: {str(e).splitlines()[0][:160]}"}
        if not self.backend.stt_loaded:
            return {"ok": False, "msg": "transcriber is still loading"}
        timings = {}
        t = time.time()
        raw = self.backend.transcribe(trimmed)
        timings["stt"] = int((time.time() - t) * 1000)
        if not raw:
            return {"ok": False, "msg": "nothing was said"}

        text = raw
        # A one- or two-word dictation ("yes please", "on it") has nothing to
        # clean and should paste instantly rather than wait for the model.
        min_words = int(_config().get("dictation_cleanup_min_words") or DEFAULT_CLEANUP_MIN_WORDS)
        if cleanup and self.backend.llm_loaded and len(raw.split()) >= min_words:
            t = time.time()
            cleaned = self._cleanup(raw, context)
            timings["cleanup"] = int((time.time() - t) * 1000)
            if cleaned:
                text = cleaned
        self.last_used = time.time()
        return {"ok": True, "text": text, "raw": raw, "ms": timings,
                "seconds": round(len(trimmed) / SR, 1)}

    # Spoken layout commands, handled in code rather than left to the model:
    # a rule that fires every time beats one that fires most of the time.
    _FORMATTING = [
        (re.compile(r"[,.]?\s*\b(new|next) paragraph\b[,.]?\s*", re.I), "\n\n"),
        (re.compile(r"[,.]?\s*\bparagraph break\b[,.]?\s*", re.I), "\n\n"),
        (re.compile(r"[,.]?\s*\b(new|next) line\b[,.]?\s*", re.I), "\n"),
        (re.compile(r"[,.]?\s*\bline break\b[,.]?\s*", re.I), "\n"),
        (re.compile(r"[,.]?\s*\bbullet point\b[,.]?\s*", re.I), "\n- "),
    ]

    @classmethod
    def apply_spoken_formatting(cls, text):
        for pattern, rep in cls._FORMATTING:
            text = pattern.sub(rep, text)
        text = re.sub(r"[ \t]+\n", "\n", text)
        text = re.sub(r"\n[ \t]+", "\n", text)
        text = re.sub(r"\n{3,}", "\n\n", text)
        return text.strip()

    @staticmethod
    def capitalise_lines(text):
        """First letter of the text and of every line, and after a bullet."""
        out = []
        for line in text.split("\n"):
            m = re.match(r"^(\s*(?:- )?)(.)(.*)$", line, re.S)
            out.append(m.group(1) + m.group(2).upper() + m.group(3) if m else line)
        return "\n".join(out)

    def _system_rules(self, context):
        """The instructions, minus the transcript. Kept separate so the
        prefix can be measured and cached independently of each request."""
        words = _dictionary()
        rules = [
            "You are a dictation cleanup filter. Return the cleaned text and nothing else.",
            "You are an editor, not a writer: the speaker's own words, sentence "
            "structure, register and length stay as they are. Do not rephrase, "
            "tighten, formalise, or make the text more concise. Do not turn a "
            "request into an instruction.",
            "Do only these things: remove filler words (um, uh, er, like, you know, "
            "sort of, okay) and false starts or repeated words; when the speaker "
            "corrects or amends themselves ('no wait X', 'actually make that X', "
            "'sorry, X', 'I mean X'), apply the amendment and drop the words that "
            "announced it; fix punctuation, capitalisation and obvious "
            "mis-transcriptions.",
            "Line breaks in the input are deliberate. Keep every one exactly where it is.",
            "Never summarise, never add anything, never answer or respond to the content.",
            "Use British English spelling.",
            "Example 1. Input: 'um so I think we should, uh, send it Tuesday no wait "
            "Wednesday, and like can you check the numbers you know before it goes'. "
            "Output: 'So I think we should send it Wednesday, and can you check the "
            "numbers before it goes.'",
            "Example 2. Input: 'we need the the invoices by friday and and actually "
            "make that thursday'. Output: 'We need the invoices by Thursday.'",
            "Example 3. Input: 'did you get the file I sent, sorry, the two files I "
            "sent this morning'. Output: 'Did you get the two files I sent this morning?'",
        ]
        if words:
            rules.append("Spell these exactly as written: " + ", ".join(words) + ".")
        if context:
            rules.append(f"The text will be pasted into {context}.")
        return "\n".join(rules)

    def _cleanup(self, raw, context):
        raw = self.apply_spoken_formatting(raw)
        max_tokens = min(2048, max(64, int(len(raw.split()) * 3)))
        with self.llm_lock:
            out = self.backend.clean(self._system_rules(context), raw, max_tokens).strip()
        # trailing spaces before line breaks are a model tic, not formatting
        out = "\n".join(line.rstrip() for line in out.splitlines()).strip()
        # strip a stray thinking block or code fence if the model insisted
        if "</think>" in out:
            out = out.split("</think>", 1)[1].strip()
        if out.startswith("```") and out.endswith("```"):
            out = out.strip("`").strip()
        # Sanity: a cleanup that balloons or vanishes is worse than the raw.
        if not out or len(out) > len(raw) * 2 + 40:
            return None
        return self.capitalise_lines(out)

    # -- word alignment for read-along --------------------------------------

    @staticmethod
    def _norm_word(w):
        return re.sub(r"[^a-z0-9]", "", w.lower())

    def align_words(self, samples_24k, words, load=True):
        """Start time in seconds of each source word within a synthesised
        chunk, from Parakeet's token timestamps; None where the recognised
        sequence could not be matched to the source (numbers spelled out,
        a mis-hearing that changed the word count). Callers interpolate
        those. ~180 ms per 5 s chunk on MLX; 98% of words matched on the
        test set.
        """
        import difflib
        if load:
            self.warm(need_llm=False)
        if not self.backend.stt_loaded or not words:
            return None
        n = int(round(len(samples_24k) * SR / 24000))
        s16 = np.interp(np.linspace(0, len(samples_24k) - 1, n),
                        np.arange(len(samples_24k)), samples_24k).astype(np.float32)
        heard = []                       # [text, start], subword tokens merged
        for text, start in self.backend.tokens(s16):
            if text.startswith(" ") or not heard:
                heard.append([text.strip(), start])
            else:
                heard[-1][0] += text
        a = [self._norm_word(w) for w in words]
        b = [self._norm_word(w) for w, _ in heard]
        starts = [None] * len(words)
        sm = difflib.SequenceMatcher(a=a, b=b, autojunk=False)
        for tag, i1, i2, j1, j2 in sm.get_opcodes():
            # equal runs, and same-length replacements (a mis-hearing) keep
            # the timing; insertions/deletions leave gaps for interpolation
            if tag == "equal" or (tag == "replace" and (i2 - i1) == (j2 - j1)):
                for d in range(i2 - i1):
                    starts[i1 + d] = heard[j1 + d][1]
        self.last_used = time.time()
        return starts

    # -- audio io ----------------------------------------------------------

    @staticmethod
    def _read_wav(path):
        try:
            with wave.open(path, "rb") as w:
                sr, ch, width = w.getframerate(), w.getnchannels(), w.getsampwidth()
                data = w.readframes(w.getnframes())
        except (OSError, wave.Error):
            return None
        if width != 2:
            return None
        s = np.frombuffer(data, dtype=np.int16).astype(np.float32) / 32768.0
        if ch > 1:
            s = s.reshape(-1, ch).mean(axis=1)
        if sr != SR:
            n = int(round(len(s) * SR / sr))
            s = np.interp(np.linspace(0, len(s) - 1, n), np.arange(len(s)), s).astype(np.float32)
        return s

    @staticmethod
    def _write_wav(path, samples):
        pcm = (np.clip(samples, -1, 1) * 32767).astype(np.int16)
        with wave.open(path, "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(SR)
            w.writeframes(pcm.tobytes())


_engine = None
_engine_lock = threading.Lock()


def engine():
    global _engine
    with _engine_lock:
        if _engine is None:
            _engine = Engine()
        return _engine
