"""Dictation engine: speech to text, then a small language model tidies it.

Two models, both open and both resident once loaded:

  Parakeet TDT 0.6B v3 (NVIDIA, CC-BY-4.0) via parakeet-mlx — transcription
      with punctuation and capitalisation built in.
  Qwen3 4B Instruct (Alibaba, Apache 2.0) via mlx-lm — removes fillers and
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
import json
import os
import re
import threading
import time
import wave

import numpy as np

HERE = os.path.dirname(os.path.realpath(os.path.abspath(__file__)))
CONFIG_PATH = os.path.join(HERE, "config.json")
DICTIONARY_PATH = os.path.join(HERE, "dictionary.txt")
VAD_PATH = os.path.join(HERE, "silero_vad.onnx")

DEFAULT_STT = "mlx-community/parakeet-tdt-0.6b-v3"
DEFAULT_CLEANUP = "mlx-community/Qwen3-4B-Instruct-2507-4bit"
DEFAULT_IDLE_MINUTES = 10
DEFAULT_CLEANUP_MIN_WORDS = 4     # shorter than this is pasted as transcribed
SR = 16000


def _config():
    try:
        with open(CONFIG_PATH) as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError):
        return {}


def _dictionary():
    try:
        with open(DICTIONARY_PATH) as f:
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
                VAD_PATH, opts, providers=["CPUExecutionProvider"])
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
        self.stt = None
        self.llm = None
        self.tok = None
        self.vad = Vad()
        # KV cache of the system prompt, keyed by its text (it varies with the
        # app being pasted into and the dictionary). Measured: processing the
        # 347-token prefix cost ~0.9-1.3 s of every cleanup; with the cache
        # only the transcript's ~50 tokens are processed, ~0.3 s.
        self._prefix = {}          # rules text -> (token ids, filled cache)
        self._prefix_order = []    # for a small LRU
        self.last_used = 0.0
        self.load_lock = threading.Lock()
        threading.Thread(target=self._idle_watch, daemon=True).start()

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
        with self.load_lock:
            cfg = _config()
            if need_llm is None:
                need_llm = bool(cfg.get("dictation_cleanup", True))
            if self.stt is None:
                from parakeet_mlx import from_pretrained
                t = time.time()
                self.stt = from_pretrained(cfg.get("stt_model") or DEFAULT_STT)
                # MLX arrays are lazy. Evaluate the weights here, in the
                # thread that loaded them, rather than letting the first
                # transcription materialise them from another thread.
                import mlx.core as mx
                mx.eval(self.stt.parameters())
                print(f"dictation: transcriber loaded in {time.time()-t:.1f}s", flush=True)
            if self.llm is None and need_llm:
                try:
                    from mlx_lm import load
                    t = time.time()
                    self.llm, self.tok = load(cfg.get("cleanup_model") or DEFAULT_CLEANUP)
                    import mlx.core as mx
                    mx.eval(self.llm.parameters())      # same cross-thread rule as above
                    print(f"dictation: cleanup model loaded in {time.time()-t:.1f}s", flush=True)
                except Exception as e:
                    self.llm = self.tok = None
                    print(f"dictation: cleanup model unavailable, using raw "
                          f"transcripts: {str(e).splitlines()[0][:160]}", flush=True)
            # Warm-up: the first transcription and first generation after a
            # load each pay ~1 s of kernel compilation. Spend it now, while
            # the key is still held, rather than on the user's first sentence.
            if self.stt is not None and not getattr(self, "_stt_warm", False):
                try:
                    self._transcribe_samples(np.zeros(SR // 2, dtype=np.float32))
                    self._stt_warm = True
                except Exception:
                    pass
            if self.llm is not None:
                try:
                    self._prefix_for(context)      # builds the cache; compiles kernels
                except Exception as e:
                    print(f"dictation: prefix cache failed: {e}", flush=True)
        self.last_used = time.time()

    def _prefix_for(self, context):
        """(prefix token ids, KV cache) for the system prompt of `context`.

        Built once per distinct rules text and reused; a small LRU because
        the set of apps dictated into is small.
        """
        import copy
        import mlx.core as mx
        from mlx_lm.models.cache import make_prompt_cache
        rules = self._system_rules(context)
        hit = self._prefix.get(rules)
        if hit is None:
            marker = " MARK "
            with_marker = self._chat(rules, marker)
            prefix_text = with_marker[:with_marker.index(marker)]
            ids = self.tok.encode(prefix_text)
            cache = make_prompt_cache(self.llm)
            t = time.time()
            self.llm(mx.array(ids)[None], cache=cache)
            mx.eval([c.state for c in cache])
            hit = (ids, cache)
            self._prefix[rules] = hit
            self._prefix_order.append(rules)
            if len(self._prefix_order) > 8:
                self._prefix.pop(self._prefix_order.pop(0), None)
            print(f"dictation: cached {len(ids)}-token prompt prefix in "
                  f"{(time.time()-t)*1000:.0f} ms", flush=True)
        ids, cache = hit
        return ids, copy.deepcopy(cache)   # generation mutates the cache

    @property
    def transcriber_loaded(self):
        return self.stt is not None

    def unload(self):
        with self.lock:
            had = self.stt is not None or self.llm is not None
            self.stt = self.llm = self.tok = None
            self._prefix.clear()
            self._prefix_order.clear()
            self._stt_warm = False
        if had:
            gc.collect()
            try:
                import mlx.core as mx
                mx.clear_cache()
            except Exception:
                pass
            print("dictation: models unloaded", flush=True)
        return had

    def _idle_watch(self):
        while True:
            time.sleep(30)
            minutes = float(_config().get("dictation_idle_unload_min") or DEFAULT_IDLE_MINUTES)
            if minutes <= 0:
                continue
            if (self.stt or self.llm) and time.time() - self.last_used > minutes * 60:
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
        if self.stt is None:
            return {"ok": False, "msg": "transcriber is still loading"}
        timings = {}
        t = time.time()
        raw = self._transcribe_samples(trimmed)
        timings["stt"] = int((time.time() - t) * 1000)
        if not raw:
            return {"ok": False, "msg": "nothing was said"}

        text = raw
        # A one- or two-word dictation ("yes please", "on it") has nothing to
        # clean and should paste instantly rather than wait for the model.
        min_words = int(_config().get("dictation_cleanup_min_words") or DEFAULT_CLEANUP_MIN_WORDS)
        if cleanup and self.llm is not None and len(raw.split()) >= min_words:
            t = time.time()
            cleaned = self._cleanup(raw, context)
            timings["cleanup"] = int((time.time() - t) * 1000)
            if cleaned:
                text = cleaned
        self.last_used = time.time()
        return {"ok": True, "text": text, "raw": raw, "ms": timings,
                "seconds": round(len(trimmed) / SR, 1)}

    def _transcribe_samples(self, samples):
        """Feed the model directly. Its transcribe(path) decodes files with
        FFmpeg, which is a large dependency for a WAV we already hold as an
        array; the log-mel front end and generate() are what it does next."""
        import mlx.core as mx
        from parakeet_mlx.audio import get_logmel
        mel = get_logmel(mx.array(samples.astype(np.float32)),
                         self.stt.preprocessor_config)
        result = self.stt.generate(mel)[0]
        return (getattr(result, "text", "") or "").strip()

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

    def _chat(self, rules, user):
        messages = [{"role": "system", "content": rules},
                    {"role": "user", "content": user}]
        try:
            return self.tok.apply_chat_template(
                messages, add_generation_prompt=True, tokenize=False,
                enable_thinking=False)
        except TypeError:
            return self.tok.apply_chat_template(
                messages, add_generation_prompt=True, tokenize=False)

    def build_prompt(self, raw, context):
        return self._chat(self._system_rules(context), raw)

    def _cleanup(self, raw, context):
        from mlx_lm import stream_generate
        raw = self.apply_spoken_formatting(raw)
        full_ids = self.tok.encode(self.build_prompt(raw, context))
        max_tokens = min(2048, max(64, int(len(raw.split()) * 3)))
        prompt_ids, cache = full_ids, None
        try:
            prefix_ids, cache = self._prefix_for(context)
            if full_ids[:len(prefix_ids)] == prefix_ids:
                prompt_ids = full_ids[len(prefix_ids):]
            else:
                cache = None            # tokeniser merged across the boundary; go uncached
        except Exception as e:
            print(f"dictation: prefix cache unavailable: {e}", flush=True)
            cache = None
        pieces = []
        for r in stream_generate(self.llm, self.tok, prompt_ids,
                                 max_tokens=max_tokens, prompt_cache=cache):
            pieces.append(r.text)
            if r.finish_reason:
                break
        out = "".join(pieces).strip()
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
        import mlx.core as mx
        from parakeet_mlx.audio import get_logmel
        if load:
            self.warm(need_llm=False)
        if self.stt is None or not words:
            return None
        n = int(round(len(samples_24k) * SR / 24000))
        s16 = np.interp(np.linspace(0, len(samples_24k) - 1, n),
                        np.arange(len(samples_24k)), samples_24k).astype(np.float32)
        result = self.stt.generate(get_logmel(mx.array(s16), self.stt.preprocessor_config))[0]
        heard = []                       # [text, start], subword tokens merged
        for sent in result.sentences:
            for tk in sent.tokens:
                if tk.text.startswith(" ") or not heard:
                    heard.append([tk.text.strip(), float(tk.start)])
                else:
                    heard[-1][0] += tk.text
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
