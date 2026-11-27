"""End-to-end check of a built engine, with no microphone or speakers.

    <engine>/runtime/python -X utf8 packaging/smoke_test.py <engine> [--cleanup]

Runs inside the engine's own runtime, against a throwaway data folder:

  1. the daemon starts and answers (the voice model loads)
  2. Kokoro speaks a sentence into a WAV (synthesis works offline)
  3. the first dictation warm-up reports the one-off model download
  4. the daemon transcribes that WAV back (Parakeet, downloaded on demand)
  5. with --cleanup, the cleanup model runs too (Qwen, a 2.5 GB download)
  6. the daemon quits and removes its endpoint

Exits non-zero on the first failure. Used by CI on each platform.
"""
import json
import os
import subprocess
import sys
import tempfile
import time


def check(ok, what):
    print(("PASS " if ok else "FAIL ") + what, flush=True)
    if not ok:
        raise SystemExit(1)


def main():
    engine = os.path.abspath(sys.argv[1])
    cleanup = "--cleanup" in sys.argv
    data = tempfile.mkdtemp(prefix="bellowflo-smoke-")
    os.environ["BELLOWFLO_DATA"] = data
    sys.path.insert(0, engine)
    import bf_ipc    # noqa: E402  (after BELLOWFLO_DATA, which bf_paths reads on import)
    import bf_paths  # noqa: E402

    with open(os.path.join(data, "config.json"), "w") as f:
        json.dump({"dictation_cleanup": cleanup}, f)

    def log_tail():
        try:
            with open(bf_paths.DAEMON_LOG, encoding="utf-8", errors="replace") as f:
                return f.read()[-3000:]
        except OSError:
            return "(no daemon log)"

    # 1. the daemon
    t = time.time()
    proc = subprocess.Popen([sys.executable, "-X", "utf8", os.path.join(engine, "daemon.py"), "--log"])
    while not bf_ipc.alive():
        if proc.poll() is not None or time.time() - t > 300:
            print(log_tail())
            check(False, "daemon started")
        time.sleep(0.5)
    check(True, f"daemon started and answered in {time.time() - t:.1f}s ({bf_ipc.transport()})")
    try:
        run(engine, data, cleanup, bf_ipc, bf_paths)
    except SystemExit:
        print(log_tail())
        raise
    finally:
        try:
            bf_ipc.request({"cmd": "quit"}, timeout=10)
        except Exception:
            pass
        try:
            proc.wait(timeout=20)
        except subprocess.TimeoutExpired:
            proc.kill()
    check(not os.path.exists(bf_ipc.SOCK_PATH) and not os.path.exists(bf_ipc.PORT_PATH),
          "daemon quit and removed its endpoint")
    print("ALL PASSED")


def run(engine, data, cleanup, bf_ipc, bf_paths):
    # 2. synthesis, through kokoro-onnx with the bundled models and espeak-ng
    import numpy as np
    import soundfile as sf
    import espeakng_loader
    from kokoro_onnx import Kokoro, EspeakConfig
    t = time.time()
    k = Kokoro(bf_paths.model("kokoro-v1.0.onnx"), bf_paths.model("voices-v1.0.bin"),
               espeak_config=EspeakConfig(lib_path=espeakng_loader.get_library_path(),
                                          data_path=espeakng_loader.get_data_path()))
    sentence = "The quick brown fox jumps over the lazy dog, and then it goes home."
    audio, sr = k.create(sentence, voice="af_heart", speed=1.0, lang="en-us")
    # 24 kHz to the 16 kHz the transcriber expects, by linear interpolation.
    n = int(len(audio) * 16000 / sr)
    audio16 = np.interp(np.linspace(0, len(audio) - 1, n), np.arange(len(audio)), audio)
    wav = os.path.join(data, "smoke.wav")
    sf.write(wav, audio16.astype(np.float32), 16000, subtype="PCM_16")
    check(len(audio) / sr > 2, f"synthesised {len(audio) / sr:.1f}s of speech in {time.time() - t:.1f}s")

    # 3. the download notice for a first dictation
    warm = bf_ipc.request({"cmd": "dictation_warm", "context": "Notepad"}, timeout=30)
    check(warm.get("ok") is True, f"dictation_warm answered: {warm}")
    print(f"     first warm-up reports downloading={warm.get('downloading')}")

    # 4. transcription (waits for the warm-up's download and load)
    t = time.time()
    reply = bf_ipc.request({"cmd": "transcribe", "path": wav, "cleanup": cleanup,
                            "context": "Notepad"}, timeout=3600)
    text = (reply.get("text") or "").lower()
    check(reply.get("ok") is True and "fox" in text and "dog" in text,
          f"transcribed in {time.time() - t:.1f}s: {reply}")

    # 5. cleanup model, when asked for
    if cleanup:
        ms = reply.get("ms") or {}
        check("cleanup" in ms, f"cleanup model ran ({ms.get('cleanup')} ms)")

    # and a second warm-up no longer reports a download
    warm = bf_ipc.request({"cmd": "dictation_warm", "context": "Notepad"}, timeout=30)
    check(warm.get("downloading") is False, "second warm-up needs no download")


if __name__ == "__main__":
    main()
