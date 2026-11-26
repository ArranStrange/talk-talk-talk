"""The two model runtimes dictation can use. Same models, different engines.

  mlx   Apple Silicon. parakeet-mlx and mlx-lm on the GPU through Metal.
        What macOS installs have always used.
  onnx  Everywhere else (Windows, Intel Macs, Linux), or on request.
        Parakeet through onnx-asr (int8, onnxruntime), Qwen as a GGUF through
        llama.cpp, which uses CUDA/Vulkan/Metal when present and the CPU
        otherwise.

Both expose the same small surface to dictate.Engine:

  load_stt(cfg) / load_llm(cfg) / unload()
  stt_loaded / llm_loaded
  transcribe(samples) -> str
  tokens(samples) -> [(text, start_seconds)]   subword pieces; a piece that
                                               starts a word begins with " "
  prime(rules)                                 cache the system prompt
  clean(rules, text, max_tokens) -> str        one cleanup generation

Pick with "dictation_backend" in config.json ("mlx", "onnx" or "auto").
"""
import copy
import importlib.util
import platform
import sys
import time

import numpy as np

SR = 16000

MLX_STT = "mlx-community/parakeet-tdt-0.6b-v3"
MLX_CLEANUP = "mlx-community/Qwen3-4B-Instruct-2507-4bit"
ONNX_STT = "nemo-parakeet-tdt-0.6b-v3"
ONNX_CLEANUP = ("unsloth/Qwen3-4B-Instruct-2507-GGUF", "Qwen3-4B-Instruct-2507-Q4_K_M.gguf")


def mlx_available():
    return (sys.platform == "darwin" and platform.machine() == "arm64"
            and importlib.util.find_spec("mlx_lm") is not None
            and importlib.util.find_spec("parakeet_mlx") is not None)


def choose(cfg):
    want = (cfg.get("dictation_backend") or "auto").lower()
    if want == "mlx" or (want == "auto" and mlx_available()):
        return MlxBackend()
    return OnnxBackend()


def _log(msg):
    print(f"dictation: {msg}", flush=True)


# --------------------------------------------------------------------------
# MLX (Apple Silicon)
# --------------------------------------------------------------------------

class MlxBackend:
    name = "mlx"

    def __init__(self):
        self.stt = self.llm = self.tok = None
        # KV cache of the system prompt, keyed by its text (it varies with the
        # app being pasted into and the dictionary). Measured: processing the
        # 347-token prefix cost ~0.9-1.3 s of every cleanup; with the cache
        # only the transcript's ~50 tokens are processed, ~0.3 s.
        self._prefix = {}          # rules text -> (token ids, filled cache)
        self._prefix_order = []    # for a small LRU

    @property
    def stt_loaded(self):
        return self.stt is not None

    @property
    def llm_loaded(self):
        return self.llm is not None

    def load_stt(self, cfg):
        from parakeet_mlx import from_pretrained
        import mlx.core as mx
        t = time.time()
        self.stt = from_pretrained(cfg.get("stt_model") or MLX_STT)
        # MLX arrays are lazy. Evaluate the weights here, in the thread that
        # loaded them, rather than letting the first transcription
        # materialise them from another thread.
        mx.eval(self.stt.parameters())
        _log(f"transcriber loaded in {time.time()-t:.1f}s (mlx)")

    def load_llm(self, cfg):
        from mlx_lm import load
        import mlx.core as mx
        t = time.time()
        try:
            self.llm, self.tok = load(cfg.get("cleanup_model") or MLX_CLEANUP)
            mx.eval(self.llm.parameters())  # same cross-thread rule as above
        except Exception:
            self.llm = self.tok = None
            raise
        _log(f"cleanup model loaded in {time.time()-t:.1f}s (mlx)")

    def unload(self):
        self.stt = self.llm = self.tok = None
        self._prefix.clear()
        self._prefix_order.clear()
        try:
            import mlx.core as mx
            mx.clear_cache()
        except Exception:
            pass

    def _generate(self, samples):
        """Feed the model directly. Its transcribe(path) decodes files with
        FFmpeg, which is a large dependency for a WAV we already hold as an
        array; the log-mel front end and generate() are what it does next."""
        import mlx.core as mx
        from parakeet_mlx.audio import get_logmel
        mel = get_logmel(mx.array(samples.astype(np.float32)),
                         self.stt.preprocessor_config)
        return self.stt.generate(mel)[0]

    def transcribe(self, samples):
        return (getattr(self._generate(samples), "text", "") or "").strip()

    def tokens(self, samples):
        result = self._generate(samples)
        return [(tk.text, float(tk.start))
                for sent in result.sentences for tk in sent.tokens]

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

    def _prefix_for(self, rules):
        """(prefix token ids, KV cache) for one system prompt. Built once per
        distinct rules text and reused; a small LRU because the set of apps
        dictated into is small."""
        import mlx.core as mx
        from mlx_lm.models.cache import make_prompt_cache
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
            _log(f"cached {len(ids)}-token prompt prefix in {(time.time()-t)*1000:.0f} ms")
        ids, cache = hit
        return ids, copy.deepcopy(cache)   # generation mutates the cache

    def prime(self, rules):
        self._prefix_for(rules)

    def clean(self, rules, text, max_tokens):
        from mlx_lm import stream_generate
        full_ids = self.tok.encode(self._chat(rules, text))
        prompt_ids, cache = full_ids, None
        try:
            prefix_ids, cache = self._prefix_for(rules)
            if full_ids[:len(prefix_ids)] == prefix_ids:
                prompt_ids = full_ids[len(prefix_ids):]
            else:
                cache = None            # tokeniser merged across the boundary; go uncached
        except Exception as e:
            _log(f"prefix cache unavailable: {e}")
            cache = None
        pieces = []
        for r in stream_generate(self.llm, self.tok, prompt_ids,
                                 max_tokens=max_tokens, prompt_cache=cache):
            pieces.append(r.text)
            if r.finish_reason:
                break
        return "".join(pieces)


# --------------------------------------------------------------------------
# ONNX + llama.cpp (Windows, Intel, Linux)
# --------------------------------------------------------------------------

class OnnxBackend:
    name = "onnx"

    def __init__(self):
        self.stt = self.stt_ts = self.llm = None

    @property
    def stt_loaded(self):
        return self.stt is not None

    @property
    def llm_loaded(self):
        return self.llm is not None

    def load_stt(self, cfg):
        import onnx_asr
        t = time.time()
        self.stt = onnx_asr.load_model(cfg.get("stt_model_onnx") or ONNX_STT,
                                       quantization="int8")
        self.stt_ts = self.stt.with_timestamps()
        _log(f"transcriber loaded in {time.time()-t:.1f}s (onnx)")

    def load_llm(self, cfg):
        from huggingface_hub import hf_hub_download
        from llama_cpp import Llama
        repo, filename = cfg.get("cleanup_model_gguf") or ONNX_CLEANUP
        t = time.time()
        # The cache first: Llama.from_pretrained lists the repo online on
        # every load, so it failed without a network even when the file was
        # already on disk.
        try:
            path = hf_hub_download(repo, filename, local_files_only=True)
        except Exception:
            path = hf_hub_download(repo, filename)
        # n_gpu_layers=-1 offloads everything the build can (CUDA, Vulkan,
        # Metal); a CPU-only build ignores it.
        self.llm = Llama(model_path=path, n_ctx=4096, n_gpu_layers=-1, verbose=False)
        _log(f"cleanup model loaded in {time.time()-t:.1f}s (llama.cpp)")

    def unload(self):
        self.stt = self.stt_ts = self.llm = None

    def transcribe(self, samples):
        return (self.stt.recognize(samples.astype(np.float32), sample_rate=SR) or "").strip()

    def tokens(self, samples):
        r = self.stt_ts.recognize(samples.astype(np.float32), sample_rate=SR)
        return list(zip(r.tokens or [], [float(t) for t in (r.timestamps or [])]))

    @staticmethod
    def _messages(rules, text):
        return [{"role": "system", "content": rules},
                {"role": "user", "content": text}]

    def prime(self, rules):
        # llama.cpp keeps the last prompt's KV cache and re-evaluates only
        # from the first token that differs, so evaluating the system prompt
        # now makes the real request pay for the transcript alone.
        t = time.time()
        self.llm.create_chat_completion(self._messages(rules, "."), max_tokens=1,
                                        temperature=0)
        _log(f"primed prompt prefix in {(time.time()-t)*1000:.0f} ms")

    def clean(self, rules, text, max_tokens):
        out = self.llm.create_chat_completion(self._messages(rules, text),
                                              max_tokens=max_tokens, temperature=0)
        return out["choices"][0]["message"]["content"] or ""
