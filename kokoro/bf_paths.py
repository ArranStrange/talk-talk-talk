"""Where Bellow Flo keeps things, on every platform.

Two places, kept apart so the engine can ship inside a signed, read-only app
bundle or Program Files:

  ENGINE_DIR  this folder: code, and the venv in a source checkout. Never
              written to.
  DATA_DIR    everything that changes: config, dictionary, the state/word
              files the UI watches, staged text, the daemon's endpoint and
              log, and the model weights (under models/).

    macOS    ~/Library/Application Support/Bellow Flo
    Windows  %LOCALAPPDATA%\\Bellow Flo
    other    $XDG_DATA_HOME/bellow-flo (~/.local/share/bellow-flo)

BELLOWFLO_DATA overrides it, for tests and for running two copies side by
side. The macOS app computes the same default independently (Paths.swift),
and so must any other front end: hooks run with no environment from us.

Standard library only: ktts and the agent hooks import this with whatever
Python the system has.
"""
import json
import os
import shutil
import sys

ENGINE_DIR = os.path.dirname(os.path.realpath(os.path.abspath(__file__)))


def _default_data_dir():
    home = os.path.expanduser("~")
    if sys.platform == "darwin":
        return os.path.join(home, "Library", "Application Support", "Bellow Flo")
    if sys.platform == "win32":
        base = os.environ.get("LOCALAPPDATA") or os.path.join(home, "AppData", "Local")
        return os.path.join(base, "Bellow Flo")
    base = os.environ.get("XDG_DATA_HOME") or os.path.join(home, ".local", "share")
    return os.path.join(base, "bellow-flo")


DATA_DIR = os.environ.get("BELLOWFLO_DATA") or _default_data_dir()
MODELS_DIR = os.path.join(DATA_DIR, "models")


def data(name):
    return os.path.join(DATA_DIR, name)


CONFIG = data("config.json")
DICTIONARY = data("dictionary.txt")
STATE = data("state")
WORD = data("word")
PENDING = data("pending.txt")
SELECTION = data("selection.txt")
DAEMON_LOG = data("daemon.log")

# Model files the engine needs, and where they come from. Kokoro and its
# voices are Apache 2.0, Silero VAD is MIT.
_KOKORO_BASE = "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0"
MODEL_URLS = {
    "kokoro-v1.0.onnx": f"{_KOKORO_BASE}/kokoro-v1.0.onnx",
    "voices-v1.0.bin": f"{_KOKORO_BASE}/voices-v1.0.bin",
    "silero_vad.onnx": "https://raw.githubusercontent.com/snakers4/silero-vad/"
                       "master/src/silero_vad/data/silero_vad.onnx",
}

# What a user owns, as opposed to what is derived or downloaded. Carried
# across by migrate().
_USER_FILES = ("config.json", "dictionary.txt", "notify_forward.json")


def model(name):
    """Path to a model file: models/ in the data folder, or, for a source
    checkout that predates the split, the engine folder."""
    preferred = os.path.join(MODELS_DIR, name)
    if os.path.exists(preferred):
        return preferred
    legacy = os.path.join(ENGINE_DIR, name)
    return legacy if os.path.exists(legacy) else preferred


def ensure():
    os.makedirs(MODELS_DIR, exist_ok=True)


def load_config():
    try:
        with open(CONFIG, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError):
        return {}


def venv_python():
    """The interpreter the daemon runs under. BELLOWFLO_PYTHON wins (a
    packaged build points it at its bundled runtime); otherwise the venv the
    installer made beside this file."""
    override = os.environ.get("BELLOWFLO_PYTHON")
    if override:
        return override
    if sys.platform == "win32":
        return os.path.join(ENGINE_DIR, "venv", "Scripts", "python.exe")
    return os.path.join(ENGINE_DIR, "venv", "bin", "python")


def write_atomic(path, text):
    """Write so a watcher never sees a half-written file."""
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(tmp, path)


def migrate(old_dir, verbose=False):
    """Carry user files and model weights over from a folder that held both
    code and data (every install before the split). Never overwrites, never
    deletes: the old folder is left exactly as it was."""
    ensure()
    moved = []
    for name in _USER_FILES:
        src, dst = os.path.join(old_dir, name), data(name)
        if os.path.isfile(src) and not os.path.exists(dst):
            shutil.copy2(src, dst)
            moved.append(name)
    for name in MODEL_URLS:
        src, dst = os.path.join(old_dir, name), os.path.join(MODELS_DIR, name)
        if os.path.isfile(src) and not os.path.exists(dst):
            try:
                os.link(src, dst)           # same volume: free and instant
            except OSError:
                shutil.copy2(src, dst)
            moved.append("models/" + name)
    if verbose:
        for name in moved:
            print(f"  carried over {name}")
    return moved


def download_models(verbose=True):
    """Fetch any missing model file into models/. Standard library only, so a
    fresh install can run it before anything else is in place."""
    import urllib.request
    ensure()
    for name, url in MODEL_URLS.items():
        dst = os.path.join(MODELS_DIR, name)
        if os.path.exists(model(name)):
            continue
        if verbose:
            print(f"  downloading {name}", flush=True)
        tmp = dst + ".part"
        with urllib.request.urlopen(url) as r, open(tmp, "wb") as f:
            shutil.copyfileobj(r, f, 1 << 20)
        os.replace(tmp, dst)


if __name__ == "__main__":
    # python bf_paths.py                 print the data folder
    # python bf_paths.py migrate DIR     carry files over from an old install
    # python bf_paths.py models          download missing model files
    args = sys.argv[1:]
    if args[:1] == ["migrate"] and len(args) == 2:
        migrate(args[1], verbose=True)
    elif args[:1] == ["models"]:
        download_models()
    else:
        print(DATA_DIR)
