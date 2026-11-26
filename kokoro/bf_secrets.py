"""API keys in the operating system's own credential store.

  macOS    the login Keychain, through /usr/bin/security
  Windows  Credential Manager (generic credentials), through advapi32
  other    not stored; the environment variable only

Every store uses the same names, so any front end can read what another
wrote: account "bellow-flo", service/target "bellowflo-<provider>". On macOS
the names from before the app was renamed are read too.

On Windows the secret (CredentialBlob) is the key as UTF-16LE, no BOM, no
terminator: what .NET's Encoding.Unicode produces, so a C# front end must
write it that way to be read here.

Standard library only. Keys are never printed, logged or put on a command
line by this module.
"""
import os
import subprocess
import sys

ACCOUNT = "bellow-flo"
PROVIDERS = ("anthropic", "openai")
ENV_VAR = {"anthropic": "ANTHROPIC_API_KEY", "openai": "OPENAI_API_KEY"}
_LEGACY = {"anthropic": ("talk-talk-talk", "ttt-anthropic"),
           "openai": ("talk-talk-talk", "ttt-openai")}


def service(provider):
    return f"bellowflo-{provider}"


def get(provider):
    """The stored key, else the environment variable, else ""."""
    key = ""
    try:
        if sys.platform == "darwin":
            key = _mac_get(ACCOUNT, service(provider))
            if not key and provider in _LEGACY:
                key = _mac_get(*_LEGACY[provider])
        elif sys.platform == "win32":
            key = _win_get(service(provider))
    except Exception:
        key = ""
    return key or os.environ.get(ENV_VAR.get(provider, ""), "").strip()


def put(provider, key):
    """Store a key given as a value (Windows; and front ends with their own
    secure input). On macOS prefer prompt_and_store(), which never lets the
    key pass through this process."""
    if sys.platform == "win32":
        _win_put(service(provider), key)
    elif sys.platform == "darwin":
        # `security` takes a value only on its command line, where other
        # processes can read it, or from its own tty prompt.
        raise OSError("on macOS, store keys with prompt_and_store()")
    else:
        raise OSError("no credential store on this platform; set "
                      + ENV_VAR.get(provider, "the environment variable"))


def prompt_and_store(provider):
    """Ask for a key at the terminal without echoing it, and store it."""
    if sys.platform == "darwin":
        # security prompts on the tty itself, so the key never enters Python.
        subprocess.run(["security", "add-generic-password", "-U", "-a", ACCOUNT,
                        "-s", service(provider), "-w"], check=True)
    else:
        import getpass
        put(provider, getpass.getpass("Key: ").strip())


# -- macOS --------------------------------------------------------------------

def _mac_get(account, svc):
    out = subprocess.run(["security", "find-generic-password", "-a", account,
                          "-s", svc, "-w"],
                         capture_output=True, text=True, timeout=10)
    return out.stdout.strip() if out.returncode == 0 else ""


# -- Windows --------------------------------------------------------------------

def _win_api():
    import ctypes
    from ctypes import wintypes

    class CREDENTIAL(ctypes.Structure):
        _fields_ = [("Flags", wintypes.DWORD),
                    ("Type", wintypes.DWORD),
                    ("TargetName", wintypes.LPWSTR),
                    ("Comment", wintypes.LPWSTR),
                    ("LastWritten", wintypes.FILETIME),
                    ("CredentialBlobSize", wintypes.DWORD),
                    ("CredentialBlob", ctypes.POINTER(ctypes.c_ubyte)),
                    ("Persist", wintypes.DWORD),
                    ("AttributeCount", wintypes.DWORD),
                    ("Attributes", ctypes.c_void_p),
                    ("TargetAlias", wintypes.LPWSTR),
                    ("UserName", wintypes.LPWSTR)]

    advapi = ctypes.WinDLL("advapi32", use_last_error=True)
    advapi.CredReadW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD,
                                 ctypes.POINTER(ctypes.POINTER(CREDENTIAL))]
    advapi.CredReadW.restype = wintypes.BOOL
    advapi.CredWriteW.argtypes = [ctypes.POINTER(CREDENTIAL), wintypes.DWORD]
    advapi.CredWriteW.restype = wintypes.BOOL
    advapi.CredFree.argtypes = [ctypes.c_void_p]
    return ctypes, CREDENTIAL, advapi


_CRED_TYPE_GENERIC = 1
_CRED_PERSIST_LOCAL_MACHINE = 2


def _win_get(target):
    ctypes, CREDENTIAL, advapi = _win_api()
    p = ctypes.POINTER(CREDENTIAL)()
    if not advapi.CredReadW(target, _CRED_TYPE_GENERIC, 0, ctypes.byref(p)):
        return ""
    try:
        c = p.contents
        blob = ctypes.string_at(c.CredentialBlob, c.CredentialBlobSize)
        return blob.decode("utf-16-le").strip()
    finally:
        advapi.CredFree(p)


def _win_put(target, key):
    ctypes, CREDENTIAL, advapi = _win_api()
    blob = key.encode("utf-16-le")
    buf = (ctypes.c_ubyte * len(blob)).from_buffer_copy(blob)
    cred = CREDENTIAL()
    cred.Type = _CRED_TYPE_GENERIC
    cred.TargetName = target
    cred.CredentialBlobSize = len(blob)
    cred.CredentialBlob = ctypes.cast(buf, ctypes.POINTER(ctypes.c_ubyte))
    cred.Persist = _CRED_PERSIST_LOCAL_MACHINE
    cred.UserName = ACCOUNT
    if not advapi.CredWriteW(ctypes.byref(cred), 0):
        raise ctypes.WinError(ctypes.get_last_error())
