using System.Diagnostics;
using System.Text.Json.Nodes;

namespace BellowFlo;

/// Hold a key to dictate: record while it is down, then transcribe, clean
/// up and paste when it comes up.
sealed class Dictation : IDisposable
{
    readonly Coordinator coord;
    readonly Recorder recorder = new();
    readonly DictationKey key = new();
    /// Speech was paused so the mic would not pick it up; resume it after.
    bool pausedSpeech;
    bool busy;
    /// The app being dictated into, named while the key goes down: resolving
    /// a process name can be slow, so it runs off the UI thread.
    Task<string> context = Task.FromResult("");
    /// Catches a key-up the hook never saw, and caps a recording's length.
    readonly System.Windows.Forms.Timer watchdog = new() { Interval = 150 };
    DateTime startedAt;
    /// Everything visible about a dictation (pausing speech, "Listening…",
    /// loading the models) waits this long after the key goes down. Right
    /// Ctrl is also an ordinary Ctrl, and a Ctrl+C typed with it should not
    /// stutter the speech or flash the pill. Recording starts at once, so no
    /// speech is lost to the wait.
    readonly System.Windows.Forms.Timer announce = new() { Interval = 220 };
    bool announced;
    static readonly TimeSpan MaxRecording = TimeSpan.FromMinutes(5);

    /// A tap shorter than this was a slip, not a sentence.
    const double MinimumHold = 0.4;

    public Dictation(Coordinator coordinator)
    {
        coord = coordinator;
        key.Pressed += KeyDown;
        key.Released += KeyUp;
        key.Chorded += Discard;
        announce.Tick += (_, _) => { announce.Stop(); Announce(); };
        watchdog.Tick += (_, _) =>
        {
            if (!recorder.IsRecording) { watchdog.Stop(); return; }
            bool tooLong = DateTime.Now - startedAt > MaxRecording;
            if (tooLong || !key.PhysicallyHeld())
            {
                Log.Write(tooLong ? "dictation: hit the 5-minute limit" : "dictation: key-up was missed; stopping");
                key.ForgetHold();
                KeyUp(false);
            }
        };
    }

    public void Start() => key.Start();

    public void Stop()
    {
        watchdog.Stop();
        announce.Stop();
        key.Stop();
        if (recorder.IsRecording) recorder.Stop(Paths.Dictation);
    }

    public void Restart() { Stop(); Start(); }

    /// The foreground app's name, which the cleanup prompt uses to match the
    /// register of what is being written (Slack vs. a code editor).
    static string AppName(IntPtr window)
    {
        try
        {
            Native.GetWindowThreadProcessId(window, out var pid);
            using var p = Process.GetProcessById((int)pid);
            var desc = p.MainModule?.FileVersionInfo.FileDescription;
            return string.IsNullOrWhiteSpace(desc) ? p.ProcessName : desc;
        }
        catch (Exception)
        {
            return "";        // elevated or protected processes refuse; context is optional
        }
    }

    void KeyDown()
    {
        if (recorder.IsRecording || busy) return;
        var window = Native.GetForegroundWindow();
        context = Task.Run(() => AppName(window));
        announced = false;
        try
        {
            recorder.Start();
            startedAt = DateTime.Now;
            watchdog.Start();
            announce.Start();
        }
        catch (Exception e)
        {
            Log.Write($"recording failed to start: {e.Message}");
            Hud.Show("Could not use the microphone.\nCheck Settings → Privacy → Microphone,\n" +
                     "and that desktop apps may use it.", 5);
            Finish(null, silent: true);
        }
    }

    /// The hold has lasted long enough to be dictation: make it visible.
    void Announce()
    {
        if (!recorder.IsRecording || announced) return;
        announced = true;
        // Load the models while the key is held, so the wait after release
        // is transcription alone.
        context.ContinueWith(t => Daemon.Send(new JsonObject { ["cmd"] = "dictation_warm", ["context"] = t.Result }));
        // Speech from the speakers would otherwise end up in the transcript.
        if (coord.State == "playing")
        {
            pausedSpeech = true;
            Daemon.Pause();
        }
        coord.DictationState("listening");
    }

    /// The key was used for a shortcut: drop the recording quietly.
    void Discard()
    {
        if (!recorder.IsRecording) return;
        announce.Stop();
        watchdog.Stop();
        recorder.Stop(Paths.Dictation);
        if (announced) Finish(null, silent: true);
    }

    async void KeyUp(bool chorded)
    {
        if (!recorder.IsRecording)
        {
            key.ForgetHold();
            return;
        }
        announce.Stop();
        watchdog.Stop();
        var seconds = recorder.Stop(Paths.Dictation);
        // A chord means the key was used for a shortcut (Ctrl+C with Right
        // Ctrl): never transcribe that, or silence becomes pasted text.
        if (chorded || seconds is not double s || s < MinimumHold)
        {
            if (announced) Finish(null, silent: true);
            return;
        }
        Announce();                      // a release inside the delay still counts
        if (recorder.LastWasSilent)
        {
            Finish(null, silent: true);
            Hud.Show("The microphone recorded only silence.\nIs it muted? If not, check Settings → Privacy & security\n" +
                     "→ Microphone, and that desktop apps may use it.", 5);
            return;
        }
        busy = true;
        coord.DictationState("transcribing");
        var cfg = new Config();
        var app = await context;
        Daemon.Request(new JsonObject
        {
            ["cmd"] = "transcribe",
            ["path"] = Paths.Dictation,
            ["cleanup"] = cfg.Bool("dictation_cleanup") ?? true,
            ["context"] = app,
        }, reply => { busy = false; Finish(reply); });
    }

    void Finish(JsonObject? reply, bool silent = false)
    {
        if (pausedSpeech)
        {
            pausedSpeech = false;
            Daemon.Resume();                 // the daemon writes "playing" itself
        }
        else
        {
            coord.DictationFinished();
        }
        bool ok = reply?["ok"] is JsonValue v && v.TryGetValue<bool>(out var b) && b;
        var text = reply?["text"] is JsonValue t && t.TryGetValue<string>(out var s) ? s : "";
        if (!ok || text.Length == 0)
        {
            var why = reply?["msg"] is JsonValue m && m.TryGetValue<string>(out var w) ? w : "no reply from the engine";
            if (!silent && why != "nothing was said") Hud.Show($"Dictation: {why}", 4);
            return;
        }
        if (reply!["ms"] is JsonObject ms)
            Log.Write($"dictation: stt {ms["stt"]}ms cleanup {ms["cleanup"]}ms {reply["seconds"]}s of speech");
        var raw = reply["raw"] is JsonValue r && r.TryGetValue<string>(out var rs) ? rs : null;
        Prefs.Remember(text, raw);
        if (new Config().Bool("dictation_paste") ?? true)
        {
            _ = Input.Paste(text);
        }
        else
        {
            Input.SetText(text);
            Hud.Show("Copied", 1);
        }
    }

    public void Dispose()
    {
        Stop();
        watchdog.Dispose();
        announce.Dispose();
        key.Dispose();
    }
}
