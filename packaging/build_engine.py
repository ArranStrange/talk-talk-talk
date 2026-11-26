#!/usr/bin/env python3
"""Assemble a self-contained speech engine for a packaged app.

    python3 packaging/build_engine.py --platform macos|windows --out DIR
                                      [--models-from DIR]

Produces DIR with:

  *.py, ktts, …   the engine code from kokoro/
  runtime/        a standalone CPython (python-build-standalone) with the
                  engine's packages installed straight into it: no venv, no
                  system Python, nothing on PATH
  *.onnx, *.bin   the voice models, so speech works offline from the first
                  launch (bf_paths.model() finds them beside the code)

Runs on the target platform: the packages are native, so a Windows engine
is built on Windows. Standard library only.

The runtime download is pinned by URL and SHA-256. The packages are pinned
by version in requirements-<platform>.txt.
"""
import argparse
import compileall
import hashlib
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
ENGINE_SRC = os.path.join(REPO, "kokoro")

# python-build-standalone, release 20261026: CPython 3.12.16.
_PBS = "https://github.com/astral-sh/python-build-standalone/releases/download/20261026/"
RUNTIMES = {
    "macos": (_PBS + "cpython-3.12.16%2B20261026-aarch64-apple-darwin-install_only.tar.gz",
              "fbf4afef53c2a6b72bb741bc06d5671a9dfaf87bd84e5aa73ac9b3d0d589f14e"),
    "windows": (_PBS + "cpython-3.12.16%2B20261026-x86_64-pc-windows-msvc-install_only.tar.gz",
                "590dfcbe3a34c07301e6332e13e2188b98655cd072b08afa45a7998dc4c22bc5"),
}

ENGINE_FILES = [
    "bf_ipc.py", "bf_paths.py", "bf_secrets.py", "daemon.py", "dictate.py",
    "dictate_backends.py", "tldr.py", "ktts", "bellowflo-set-key",
    "speak_response.py", "codex_notify.py", "cursor_notify.py",
]

# Parts of the standard library a speech engine never uses. Removing them
# makes the download smaller; none is imported by the engine or its packages.
STDLIB_PRUNE = ["test", "idlelib", "tkinter", "turtledemo", "ensurepip", "lib2to3",
                "pydoc_data"]


def say(msg):
    print(f"==> {msg}", flush=True)


def fetch(url, sha256, dest):
    say(f"downloading {url.rsplit('/', 1)[-1]}")
    h = hashlib.sha256()
    with urllib.request.urlopen(url) as r, open(dest, "wb") as f:
        while True:
            chunk = r.read(1 << 20)
            if not chunk:
                break
            h.update(chunk)
            f.write(chunk)
    if h.hexdigest() != sha256:
        raise SystemExit(f"checksum mismatch for {url}: got {h.hexdigest()}")


def runtime_python(runtime, platform):
    if platform == "windows":
        return os.path.join(runtime, "python.exe")
    return os.path.join(runtime, "bin", "python3")


def build_runtime(platform, out):
    url, sha = RUNTIMES[platform]
    runtime = os.path.join(out, "runtime")
    with tempfile.TemporaryDirectory() as tmp:
        tarball = os.path.join(tmp, "python.tar.gz")
        fetch(url, sha, tarball)
        say("unpacking the runtime")
        with tarfile.open(tarball) as t:
            if hasattr(tarfile, "data_filter"):
                t.extractall(tmp, filter="data")
            else:
                # Older Pythons (macOS's own 3.9) lack extraction filters:
                # refuse any path that would land outside the folder.
                root = os.path.realpath(tmp)
                for m in t.getmembers():
                    dest = os.path.realpath(os.path.join(tmp, m.name))
                    if not dest.startswith(root + os.sep) or m.isdev():
                        raise SystemExit(f"unsafe path in the runtime archive: {m.name}")
                t.extractall(tmp)
        # The archive's single top-level folder is "python".
        shutil.move(os.path.join(tmp, "python"), runtime)

    py = runtime_python(runtime, platform)
    say("installing the engine's packages")
    req = os.path.join(HERE, f"requirements-{platform}.txt")
    env = dict(os.environ, PIP_DISABLE_PIP_VERSION_CHECK="1")
    subprocess.run([py, "-m", "pip", "install", "--no-cache-dir", "--no-warn-script-location",
                    "-r", req], check=True, env=env)

    lib = (os.path.join(runtime, "Lib") if platform == "windows"
           else os.path.join(runtime, "lib", "python3.12"))
    for name in STDLIB_PRUNE:
        shutil.rmtree(os.path.join(lib, name), ignore_errors=True)
    # Bytecode now, so the first launch does not pay for compiling it (and
    # so nothing tries to write into a signed, read-only bundle later).
    say("precompiling")
    compileall.compile_dir(lib, quiet=1, workers=0, legacy=False)
    return py


def copy_engine(out):
    say("copying the engine code")
    for name in ENGINE_FILES:
        shutil.copy2(os.path.join(ENGINE_SRC, name), os.path.join(out, name))


def copy_models(out, models_from):
    sys.path.insert(0, ENGINE_SRC)
    import bf_paths  # noqa: E402  (stdlib only; its URLs are the source of truth)
    for name, url in bf_paths.MODEL_URLS.items():
        dst = os.path.join(out, name)
        src = os.path.join(models_from, name) if models_from else None
        if src and os.path.exists(src):
            say(f"copying {name}")
            shutil.copy2(src, dst)
        else:
            say(f"downloading {name}")
            with urllib.request.urlopen(url) as r, open(dst + ".part", "wb") as f:
                shutil.copyfileobj(r, f, 1 << 20)
            os.replace(dst + ".part", dst)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--platform", choices=sorted(RUNTIMES), required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--models-from", help="a folder already holding the model files")
    ap.add_argument("--no-models", action="store_true",
                    help="leave the models out; the engine downloads them on first run")
    a = ap.parse_args()

    out = os.path.abspath(a.out)
    if os.path.exists(out):
        shutil.rmtree(out)
    os.makedirs(out)
    copy_engine(out)
    py = build_runtime(a.platform, out)
    if not a.no_models:
        copy_models(out, a.models_from)

    say("checking the engine imports")
    subprocess.run([py, "-c", "import kokoro_onnx, onnxruntime, sounddevice, soundfile, "
                    "huggingface_hub, espeakng_loader; print('imports ok')"], check=True)
    size = sum(os.path.getsize(os.path.join(d, f)) for d, _, fs in os.walk(out) for f in fs)
    say(f"engine ready: {out} ({size / 1e6:.0f} MB)")


if __name__ == "__main__":
    main()
