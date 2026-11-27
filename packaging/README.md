# Packaging

How the downloadable builds are made. Each one is self-contained: the app,
a standalone Python with the engine's packages already installed, and the
voice models.

| | macOS | Windows |
|---|---|---|
| Build it | `macos/package.sh [version]` | `windows\package.ps1 -Version x.y.z` |
| Output | `dist/BellowFlo-<v>-macos-arm64.dmg` | `dist/BellowFlo-<v>-windows-x64-setup.exe` |
| Engine inside | `Bellow Flo.app/Contents/Resources/engine` | `%LOCALAPPDATA%\Programs\Bellow Flo\engine` |
| Size | about 500 MB DMG (1.4 GB installed) | see the latest release |

Both scripts call [`build_engine.py`](build_engine.py), which:
1. copies the engine code from `kokoro/`;
2. unpacks a pinned
   [python-build-standalone](https://github.com/astral-sh/python-build-standalone)
   CPython 3.12, checking its SHA-256;
3. installs [`requirements-<platform>.txt`](.), whose versions are pinned;
4. trims unused parts of the standard library and precompiles everything;
5. copies or downloads the voice models.

The apps look for a bundled engine before anything else, and `bf_paths`
prefers `engine/runtime` over a venv.

Dictation models (Parakeet and Qwen, about 3 GB) are not bundled. The first
dictation downloads them into the Hugging Face cache. While that happens,
`dictation_warm` replies `"downloading": true` and the apps say so. If the
voice models are ever missing, the daemon downloads them at start and sets
the state to `downloading`, and the apps wait for it.

## CI and releases

[`.github/workflows/package.yml`](../.github/workflows/package.yml) runs on
pull requests, on pushes to `main` and by hand. It:
- builds both packages;
- installs the Windows one silently;
- runs [`smoke_test.py`](smoke_test.py) inside the installed engine. This
  starts the daemon, speaks a sentence into a WAV, transcribes it back,
  runs the cleanup model and quits;
- launches the installed app and checks its log;
- uninstalls it.

The macOS job runs the smoke test in the app bundle. Both packages are kept
as workflow artifacts.

To release, push a tag:

```bash
git tag v1.0.0 && git push origin v1.0.0
```

The same jobs then attach both packages to a new GitHub release.

## Signing

Unsigned builds work, but each OS warns the first time they're opened:
- macOS asks for **Open Anyway** in Privacy & Security.
- Windows SmartScreen shows **More info → Run anyway**.

Signing removes those warnings for everyone.

**macOS** needs an Apple Developer Program membership ($99 a year):
1. Create a *Developer ID Application* certificate and install it in your
   keychain.
2. Store notarization credentials once:
   `xcrun notarytool store-credentials bellowflo --apple-id … --team-id …`.
3. Build with
   `BELLOWFLO_SIGN_IDENTITY="Developer ID Application: …" BELLOWFLO_NOTARY_PROFILE=bellowflo macos/package.sh v1.0.0`.

The script signs every native file inside the app with the hardened runtime
and the exceptions in [`macos/entitlements.plist`](../macos/entitlements.plist).
It then notarizes the DMG and staples the ticket to it.

**Windows** needs an Authenticode code-signing certificate:
1. Set `BELLOWFLO_SIGN_PFX` to the `.pfx` file and `BELLOWFLO_SIGN_PASSWORD`
   to its password.
2. Run `package.ps1`. It signs the app and the installer with `signtool`
   and timestamps both.

An OV certificate still shows SmartScreen warnings until the app builds
reputation. An EV certificate, or Azure Trusted Signing, avoids them sooner.

To sign in CI, store the certificate and passwords as repository secrets and
pass them to these environment variables in the workflow.
