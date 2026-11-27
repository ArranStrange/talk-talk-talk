# Bellow Flo for Windows

A system tray app for Windows 10 and 11 that matches the macOS menu bar app. It uses the same Python speech
engine (`../kokoro`), so voices, TL;DR, read-along and dictation behave the
same on both platforms.

Most people should use the installer from the
[Releases page](https://github.com/ArranStrange/talk-talk-talk/releases),
which has everything inside (see the main README). The rest of this page
is for building it yourself.

## Set up from source

You need Python 3.11–3.13 (from python.org, with the `py` launcher) and the
[.NET 10 SDK](https://dotnet.microsoft.com/download). Then, from the repo
root:

```powershell
powershell -ExecutionPolicy Bypass -File windows\setup-dev.ps1
```

The script:
- creates `kokoro\venv`;
- installs the ONNX speech and dictation packages;
- downloads the voice models into `%LOCALAPPDATA%\Bellow Flo\models`;
- says a test sentence;
- builds the app.

Then run:

```powershell
windows\BellowFlo\bin\Release\net10.0-windows\BellowFlo.exe
```

The first dictation downloads the Parakeet and Qwen models (about 3 GB) into
`%USERPROFILE%\.cache\huggingface`. If that download stalls, set
`HF_HUB_DISABLE_XET=1` and try again.

## Using it

The mark in the system tray changes colour with the state. Left or right
click opens the menu. The floating pill appears whenever something is
happening. Drag it anywhere, and use **Reset pill position** in the menu if
it gets lost.

| Shortcut | Does |
|---|---|
| Ctrl+Alt+S | speak the selected text |
| Ctrl+Alt+R | open the selection in the reader |
| Ctrl+Alt+P | speak the waiting reply, or pause/resume |
| Ctrl+Alt+← | rewind 10 s |
| Ctrl+Alt+X | cancel / dismiss / stop |
| Ctrl+Alt+A | auto-read on/off |
| Ctrl+Alt+T | TL;DR on/off |
| hold Right Ctrl | dictate; let go to paste |

If another app already owns a shortcut, Bellow Flo says which ones on start.

On keyboard layouts where AltGr (which Windows treats as Ctrl+Alt) types
letters with these keys, as Polish AltGr+S types ś, the shortcuts move to
Ctrl+Alt+Shift, or to Ctrl+Win if that clashes too. That keeps those letters
typeable. The Shortcuts… menu item shows the set in use. To choose one
yourself, set `"hotkey_modifiers"` in `config.json` to `"ctrl+alt"`,
`"ctrl+alt+shift"` or `"ctrl+win"`.

Dictation ignores the key when you use it as part of a shortcut: a Right
Ctrl+C never starts a transcription.

The dictation key can also be **Right Alt** or **Ctrl + Win** (menu →
Dictation → Dictation key).
- **Right Alt** is AltGr on many European keyboards, where it types
  characters, so Right Ctrl is the default.
- **Ctrl + Win** matches Wispr Flow.

API keys for the Claude or ChatGPT summariser are entered from the menu
(TL;DR options → Store … API key). They go into Windows Credential Manager,
where the engine reads them.

## How it differs from the Mac app

- **Engine connection:** the app reaches the engine over loopback TCP, not a
  Unix socket. The daemon writes its port and a per-run token to
  `daemon.port` in the data folder and refuses requests without the token.
- **Dictation key:** it's watched with a low-level keyboard hook that only
  listens and never swallows keys. No special permission is needed, unlike
  macOS Accessibility.
- **Microphone:** Windows asks for access under Settings → Privacy &
  security → Microphone, where "Let desktop apps access your microphone"
  must be on.
- **Clipboard:** copying the selection and pasting dictation use simulated
  Ctrl+C / Ctrl+V. Both wait for you to let go of Ctrl/Alt first, so a
  hotkey's own keys don't turn Ctrl+C into Ctrl+Alt+C. The clipboard's
  text is put back afterwards.
- **Settings:** UI preferences (auto-read, read-along, reader speed, pill
  position, recent dictations) are in `app.json` in the data folder. The
  Mac app keeps these in its own preferences instead.
- **Log:** the app writes `BellowFlo.log` in the data folder, next to
  `daemon.log`. Menu → Open data folder opens it.

## Finding the engine

The app looks in these places, in order:
1. `BELLOWFLO_ENGINE`;
2. an `engine` folder beside the exe, which the installer will use;
3. a `kokoro` folder in any parent directory, which is how a source checkout
   works.

Python is taken from `BELLOWFLO_PYTHON` if set, otherwise from
`<engine>\venv\Scripts\python.exe`.

## Building the installer

```powershell
powershell -ExecutionPolicy Bypass -File windows\package.ps1 -Version 1.2.3
```

This needs the .NET 10 SDK, Python, the Visual Studio Build Tools (because
llama-cpp-python compiles) and Inno Setup 6. CI builds it on every pull
request; see [packaging](../packaging/README.md).

## Not yet done

- Hooking up the agent hooks (Claude Code, Codex, Cursor). The scripts
  are already cross-platform, but nothing installs them on Windows yet.
