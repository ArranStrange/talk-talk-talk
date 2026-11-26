using System.Diagnostics;
using System.Reflection;
using System.Text.Json.Nodes;

namespace BellowFlo;

enum Destination { Speak, Reader }

/// Owns the app's state and wires the pieces together: the tray icon and
/// its menu, the pill, the reader, hotkeys, dictation and TL;DR. The
/// counterpart of the macOS app's Coordinator and MenuBarController.
sealed class Coordinator : ApplicationContext
{
    readonly NotifyIcon tray = new();
    readonly ContextMenuStrip menu = new();
    readonly Pill pill = new();
    readonly Reader reader = new();
    readonly Tldr tldr = new();
    Hotkeys? hotkeys;
    StateWatcher? watcher;
    Dictation? dictation;
    readonly System.Windows.Forms.Timer readyTimer = new() { Interval = 60000 };

    public string State { get; private set; } = "idle";
    string lastSeenState = "idle";
    bool autoPlayFired;

    // -- lifecycle ----------------------------------------------------------------

    public void Start()
    {
        // WinForms installs its synchronisation context with the first
        // control; make sure it exists before anything captures it.
        if (SynchronizationContext.Current is not WindowsFormsSynchronizationContext)
            SynchronizationContext.SetSynchronizationContext(new WindowsFormsSynchronizationContext());
        Daemon.Init();
        Hud.Init();
        Foreground.Start();

        tray.Text = "Bellow Flo";
        tray.Icon = Look.TrayIcon("idle", SystemInformation.SmallIconSize.Width * 2);
        tray.ContextMenuStrip = menu;
        tray.Visible = true;
        menu.Opening += (_, _) => BuildMenu();
        // A left click opens the same menu, as the Mac menu bar item does.
        tray.MouseUp += (_, e) =>
        {
            if (e.Button != MouseButtons.Left) return;
            typeof(NotifyIcon).GetMethod("ShowContextMenu", BindingFlags.Instance | BindingFlags.NonPublic)
                ?.Invoke(tray, null);
        };

        pill.Hit += HandlePill;
        readyTimer.Tick += (_, _) => { readyTimer.Stop(); DismissReady(); };

        watcher = new StateWatcher();
        watcher.StateChanged += Refresh;
        watcher.WordChanged += pill.WordFileChanged;
        watcher.Start();

        BindHotkeys();
        dictation = new Dictation(this);
        dictation.Start();
        Refresh();
        if (Prefs.ReadAlong) Daemon.Command("align_warm", boot: false);

        Log.Write($"started: hotkeys={hotkeys?.Count}/7 failed=[{string.Join(", ", hotkeys?.Failed ?? Array.Empty<string>())}] " +
                  $"engine={Paths.EngineDir} python={File.Exists(Paths.Python)} data={Paths.DataDir} state={State}");

        if (hotkeys?.Failed.Count > 0)
            Hud.Show("Some shortcuts are taken by another app:\n" + string.Join(", ", hotkeys.Failed), 5);
        else if (!File.Exists(Paths.Python))
            Hud.Show("Bellow Flo's speech engine is not installed yet.", 5);
        else if (!Prefs.StartedBefore)
        {
            Prefs.StartedBefore = true;
            tray.ShowBalloonTip(6000, "Bellow Flo is running",
                $"It lives in the system tray. Select text and press {Hk}S to hear it; " +
                $"{DictationKey.Label(DictationKey.Current)} to dictate.", ToolTipIcon.Info);
        }
    }

    void BindHotkeys()
    {
        hotkeys = new Hotkeys(new[] { Keys.S, Keys.R, Keys.P, Keys.X, Keys.A, Keys.T, Keys.Left });
        hotkeys.Bind(Keys.S, "S", () => ReadSelection(Destination.Speak));
        hotkeys.Bind(Keys.R, "R", ReaderHotkey);
        hotkeys.Bind(Keys.P, "P", PlayOrPause);
        hotkeys.Bind(Keys.X, "X", StopOrDismiss);
        hotkeys.Bind(Keys.A, "A", ToggleAutoRead);
        hotkeys.Bind(Keys.T, "T", ToggleTldr);
        // Ctrl+Win+Left is Windows' own "previous desktop", so under that
        // fallback rewind moves to the comma key.
        if (hotkeys.Prefix == "Ctrl+Win+") { RewindKey = ","; hotkeys.Bind(Keys.Oemcomma, ",", () => Daemon.Back()); }
        else hotkeys.Bind(Keys.Left, "Left", () => Daemon.Back());
    }

    string RewindKey = "←";

    string Hk => hotkeys?.Prefix ?? "Ctrl+Alt+";

    // -- state --------------------------------------------------------------------

    void WriteState(string s) => Paths.Write(s, Paths.State);

    public void Refresh()
    {
        var raw = Paths.Read(Paths.State).Trim();
        var next = raw.Length == 0 ? "idle" : raw;

        // Something genuinely new un-hides a pill that was dismissed with ✕.
        if (pill.Dismissed && next != lastSeenState && next is "ready" or "synthesizing")
            pill.Dismissed = false;
        lastSeenState = next;
        State = next;

        readyTimer.Stop();
        tray.Icon = Look.TrayIcon(State, SystemInformation.SmallIconSize.Width * 2);
        var tip = "Bellow Flo — " + (Look.MenuLabel.TryGetValue(State, out var l) ? l : State);
        tray.Text = tip.Length > 120 ? tip[..120] : tip;      // NotifyIcon throws past 127

        if (State == "idle")
        {
            pill.Dismissed = false;
            pill.HidePill();
            autoPlayFired = false;
            return;
        }
        if (pill.Dismissed)
        {
            pill.HidePill();
            return;
        }

        pill.UpdateState(State, Prefs.AutoRead, new Config().TldrOn, Prefs.ReadAlong);

        if (State == "ready")
        {
            if (Prefs.AutoRead)
            {
                if (!autoPlayFired)
                {
                    autoPlayFired = true;
                    PlayPending(Destination.Speak);
                }
            }
            else
            {
                readyTimer.Start();
            }
        }
        else
        {
            autoPlayFired = false;
        }
    }

    public void DismissReady() => WriteState("idle");

    /// Dictation writes its own states into the file the daemon uses.
    public void DictationState(string s) { WriteState(s); Refresh(); }

    /// Dictation is over: put the file back to whatever the engine is really
    /// doing, rather than "idle" over speech that was merely paused.
    public void DictationFinished()
    {
        if (State is not ("listening" or "transcribing")) return;
        Daemon.Request(new JsonObject { ["cmd"] = "status" }, reply =>
        {
            if (State is not ("listening" or "transcribing")) return;
            var real = reply?["msg"] is JsonValue v && v.TryGetValue<string>(out var s) ? s : "idle";
            WriteState(real is "idle" or "playing" or "paused" or "synthesizing" ? real : "idle");
            Refresh();
        }, boot: false);
    }

    // -- delivery -------------------------------------------------------------------

    void Deliver(string text, Destination to)
    {
        if (text.Length == 0) return;
        if (to == Destination.Speak) Daemon.Say(text); else reader.Open(text);
    }

    /// TL;DR decides whether the text is summarised; the caller decides
    /// where it lands.
    void DeliverText(string raw, Destination to)
    {
        var text = raw.Trim();
        if (!new Config().TldrOn || Tldr.TooShort(text))
        {
            Deliver(text, to);
            return;
        }
        if (SummaryCache.Lookup(text) is string cached)
        {
            Log.Write("summary reused from cache");
            Deliver(cached, to);
            return;
        }
        if (tldr.IsRunning) return;
        WriteState("summarising");
        Refresh();
        tldr.Run(text, (summary, error) =>
        {
            WriteState("idle");
            Refresh();
            if (summary != null)
            {
                SummaryCache.Store(summary, text);
                Deliver(summary, to);
            }
            else if (!string.IsNullOrEmpty(error))
            {
                Hud.Show($"TL;DR failed: {error}", 4);
            }
        });
    }

    public void PlayPending(Destination to) => DeliverText(Paths.Read(Paths.Pending), to);

    public void CancelSummarise()
    {
        tldr.Cancel();
        WriteState("idle");
    }

    /// `fromMenu`: the tray menu took focus, so hand it back to the user's
    /// window before copying, or Ctrl+C would go to the taskbar.
    public async void ReadSelection(Destination to, bool fromMenu = false)
    {
        if (fromMenu && !await Foreground.ReturnToWork())
        {
            Hud.Show("Could not get back to your window.\nUse the shortcut instead: " + Hk + "S", 3);
            return;
        }
        var text = await Input.CopySelection();
        if (text == null) { Hud.Show("No text selected"); return; }
        Paths.Write(text, Paths.Selection);          // staged where the hooks and ktts expect it
        DeliverText(text, to);
    }

    public void ReadClipboard(Destination to)
    {
        var clip = Input.GetText();
        if (string.IsNullOrEmpty(clip)) { Hud.Show("Clipboard is empty"); return; }
        Paths.Write(clip, Paths.Selection);
        DeliverText(clip, to);
    }

    // -- actions ----------------------------------------------------------------------

    public void PlayOrPause()
    {
        if (State == "ready") PlayPending(Destination.Speak); else Daemon.Toggle();
    }

    public void StopOrDismiss()
    {
        switch (State)
        {
            case "summarising": CancelSummarise(); break;
            case "ready": DismissReady(); break;
            default: Daemon.Stop(); break;
        }
    }

    void ReaderHotkey()
    {
        if (reader.IsOpen) reader.CloseReader(); else ReadSelection(Destination.Reader);
    }

    public void ToggleAutoRead()
    {
        Prefs.AutoRead = !Prefs.AutoRead;
        Hud.Show(Prefs.AutoRead ? "Auto-read: ON" : "Auto-read: OFF");
        Refresh();
        if (Prefs.AutoRead && State == "ready") PlayPending(Destination.Speak);
    }

    public void ToggleTldr()
    {
        var now = !new Config().TldrOn;
        Config.Set("tldr_replies", now);
        Hud.Show(now ? "TL;DR: ON" : "TL;DR: OFF");
        Refresh();
    }

    public void ToggleReadAlong()
    {
        Prefs.ReadAlong = !Prefs.ReadAlong;
        Hud.Show(Prefs.ReadAlong ? "Read-along: ON" : "Read-along: OFF");
        Refresh();
        // Load the aligner now, while nothing is being synthesised.
        if (Prefs.ReadAlong) Daemon.Command("align_warm");
    }

    public void BringPillToFront() =>
        pill.BringToFront(State, Prefs.AutoRead, new Config().TldrOn, Prefs.ReadAlong);

    void HandlePill(PillHit hit)
    {
        switch (hit)
        {
            case PillHit.Auto: ToggleAutoRead(); break;
            case PillHit.Rsvp: ToggleReadAlong(); break;
            case PillHit.Tldr: ToggleTldr(); break;
            case PillHit.Back: Daemon.Back(); break;
            case PillHit.Toggle: PlayOrPause(); break;
            case PillHit.Stop: StopOrDismiss(); break;
        }
    }

    // -- menu ---------------------------------------------------------------------------

    static readonly (string group, string[] ids, string lang)[] Voices =
    {
        ("American female", new[] { "af_heart", "af_bella", "af_nicole", "af_sarah", "af_sky",
                                    "af_nova", "af_alloy", "af_aoede", "af_jessica", "af_kore", "af_river" }, "en-us"),
        ("American male", new[] { "am_michael", "am_adam", "am_puck", "am_echo", "am_eric",
                                  "am_fenrir", "am_liam", "am_onyx" }, "en-us"),
        ("British female", new[] { "bf_emma", "bf_isabella", "bf_alice", "bf_lily" }, "en-gb"),
        ("British male", new[] { "bm_george", "bm_fable", "bm_daniel", "bm_lewis" }, "en-gb"),
    };
    static readonly double[] Speeds = { 0.8, 0.9, 1.0, 1.1, 1.25, 1.5 };
    static readonly (string id, string label)[] Providers =
    {
        ("claude-cli", "Claude Code CLI (no key, uses your plan)"),
        ("anthropic", "Claude API (needs key)"),
        ("openai", "ChatGPT API (needs key)"),
        ("extractive", "Local, no AI (free, instant)"),
    };
    static readonly Dictionary<string, string[]> Models = new()
    {
        ["claude-cli"] = new[] { "haiku", "sonnet", "opus" },
        ["anthropic"] = new[] { "claude-haiku-4-5-20251001", "claude-sonnet-5", "claude-opus-5" },
        ["openai"] = new[] { "gpt-4o-mini", "gpt-4o" },
        ["extractive"] = Array.Empty<string>(),
    };

    static ToolStripMenuItem Item(ToolStripItemCollection into, string text, Action? action = null,
                                  bool check = false, bool enabled = true)
    {
        var item = new ToolStripMenuItem(text) { Checked = check, Enabled = enabled && action != null };
        if (action != null) item.Click += (_, _) => action();
        into.Add(item);
        return item;
    }

    static ToolStripMenuItem Sub(ToolStripItemCollection into, string text)
    {
        var item = new ToolStripMenuItem(text);
        into.Add(item);
        return item;
    }

    static string Trim(double d) => d == Math.Round(d) ? ((int)d).ToString() : d.ToString("0.##");

    static string OneLine(string text, int limit = 60)
    {
        var flat = string.Join(" ", Rsvp.Words(text));
        return flat.Length <= limit ? flat : flat[..(limit - 1)].TrimEnd() + "…";
    }

    static void Open(string path) =>
        Process.Start(new ProcessStartInfo(path) { UseShellExecute = true });

    /// Rebuilt every time it opens, so it is never stale.
    void BuildMenu()
    {
        var m = menu.Items;
        m.Clear();
        var st = State;
        var cfg = new Config();
        bool speaking = st is "playing" or "paused";

        Item(m, Look.MenuLabel.TryGetValue(st, out var label) ? label : st, enabled: false);

        m.Add(new ToolStripSeparator());
        Item(m, "Auto-read", ToggleAutoRead, Prefs.AutoRead);
        Item(m, "TL;DR", ToggleTldr, cfg.TldrOn);
        Item(m, "Bring to front", BringPillToFront);

        m.Add(new ToolStripSeparator());
        if (st == "summarising")
        {
            Item(m, "Cancel summarising", CancelSummarise);
        }
        else if (st == "ready")
        {
            Item(m, "Play reply", () => PlayPending(Destination.Speak));
            Item(m, "Dismiss reply", DismissReady);
        }
        else
        {
            Item(m, st == "paused" ? "Resume" : "Pause", Daemon.Toggle, enabled: speaking);
            Item(m, "Rewind 10s", () => Daemon.Back(), enabled: speaking);
            Item(m, "Stop", Daemon.Stop, enabled: speaking);
        }

        m.Add(new ToolStripSeparator());
        Item(m, "Speak selection", () => ReadSelection(Destination.Speak, fromMenu: true));
        Item(m, "Selection → reader", () => ReadSelection(Destination.Reader, fromMenu: true));
        Item(m, "Speak clipboard", () => ReadClipboard(Destination.Speak));
        Item(m, "Clipboard → reader", () => ReadClipboard(Destination.Reader));
        Item(m, "Speak the last reply", () => PlayPending(Destination.Speak), enabled: st == "ready");
        Item(m, "Last reply → reader", () => PlayPending(Destination.Reader), enabled: st == "ready");

        m.Add(new ToolStripSeparator());
        Item(m, "Read-along words while speaking", ToggleReadAlong, Prefs.ReadAlong);
        var wpm = Sub(m, $"Reader speed ({Prefs.ReaderWpm} wpm)");
        foreach (var w in new[] { 200, 250, 300, 350, 400, 500, 600, 800 })
            Item(wpm.DropDownItems, $"{w} wpm", () => Prefs.ReaderWpm = w, Prefs.ReaderWpm == w);
        if (reader.IsOpen)
        {
            var (at, total) = reader.Position;
            Item(m, $"Reader position: {at} / {total}", enabled: false);
            Item(m, "Close reader", reader.CloseReader);
        }

        m.Add(new ToolStripSeparator());
        BuildTldrMenu(Sub(m, "TL;DR options").DropDownItems, cfg);

        m.Add(new ToolStripSeparator());
        BuildDictationMenu(Sub(m, "Dictation").DropDownItems, cfg);

        m.Add(new ToolStripSeparator());
        var voice = Sub(m, $"Voice ({cfg.Voice})");
        foreach (var (group, ids, lang) in Voices)
        {
            var sub = Sub(voice.DropDownItems, group);
            foreach (var id in ids)
            {
                var bare = id[(id.IndexOf('_') + 1)..];
                var name = char.ToUpper(bare[0]) + bare[1..];
                Item(sub.DropDownItems, name, () =>
                {
                    Config.Update(o => { o["voice"] = id; o["lang"] = lang; });
                    Hud.Show($"Voice: {id}");
                }, cfg.Voice == id);
            }
        }
        var speed = Sub(m, $"Speaking speed ({Trim(cfg.Speed)}x)");
        foreach (var sp in Speeds)
            Item(speed.DropDownItems, Trim(sp) + "x", () =>
            {
                Config.Set("speed", sp);
                Hud.Show($"Speed: {Trim(sp)}x");
            }, Math.Abs(cfg.Speed - sp) < 0.001);

        m.Add(new ToolStripSeparator());
        Item(m, "Shortcuts…", () => Hud.Show(
            $"{Hk}S  speak selection\n" +
            $"{Hk}R  selection in the reader\n" +
            $"{Hk}P  speak the reply / pause\n" +
            $"{Hk}{RewindKey}  rewind 10s\n" +
            $"{Hk}X  cancel / dismiss / stop\n" +
            $"{Hk}A  auto-read on/off\n" +
            $"{Hk}T  TL;DR on/off\n" +
            $"{DictationKey.Label(DictationKey.Current)} to dictate\n" +
            "In the reader: hold R to read · ↑↓ speed · ←→ step · Esc close", 7));
        Item(m, "Start at login", () =>
        {
            var problem = LoginItem.Set(!LoginItem.Enabled);
            Hud.Show(problem ?? (LoginItem.Enabled ? "Will start at login" : "Will not start at login"),
                     problem == null ? 1.6 : 5);
        }, LoginItem.Enabled);
        Item(m, "Reset pill position", () => { Prefs.PillAnchor = null; BringPillToFront(); });
        Item(m, "Restart speech engine", () =>
        {
            Daemon.Quit();
            Hud.Show("Engine will reload on next use");
        });
        Item(m, "Open data folder", () => Open(Paths.DataDir));
        m.Add(new ToolStripSeparator());
        Item(m, "Quit Bellow Flo", Quit);
    }

    void BuildTldrMenu(ToolStripItemCollection m, Config cfg)
    {
        var current = cfg.TldrProvider;
        var prov = Sub(m, "Provider");
        foreach (var (id, label) in Providers)
            Item(prov.DropDownItems, label, () =>
            {
                Config.Update(o => { o["tldr_provider"] = id; o.Remove("tldr_model"); });
                Hud.Show($"TL;DR via {label}");
            }, current == id);

        var available = Models.TryGetValue(current, out var list) ? list : Array.Empty<string>();
        if (available.Length > 0)
        {
            var model = Sub(m, "Model");
            var chosen = cfg.TldrModel ?? available[0];
            foreach (var name in available)
                Item(model.DropDownItems, name, () => Config.Set("tldr_model", name), chosen == name);
            model.DropDownItems.Add(new ToolStripSeparator());
            Item(model.DropDownItems, "Custom model…", () =>
            {
                var v = Prompt.Ask("TL;DR model", $"Model identifier to send to the {current} API:",
                                   cfg.TldrModel ?? "");
                if (!string.IsNullOrWhiteSpace(v)) Config.Set("tldr_model", v.Trim());
            });
        }

        var len = Sub(m, "Summary length");
        foreach (var n in new[] { 1, 2, 3, 5 })
            Item(len.DropDownItems, $"{n} sentence{(n == 1 ? "" : "s")}",
                 () => Config.Set("tldr_sentences", n), cfg.TldrSentences == n);

        var min = Sub(m, $"Only summarise (over {cfg.TldrMinWords} words)");
        foreach (var n in new[] { 40, 70, 120, 200 })
            Item(min.DropDownItems, $"over {n} words", () =>
            {
                Config.Set("tldr_min_words", n);
                Hud.Show($"Only summarising text over {n} words");
            }, cfg.TldrMinWords == n);

        m.Add(new ToolStripSeparator());
        Item(m, "Store Claude API key…", () => Credentials.AskAndStore("anthropic", "Claude", "sk-ant-"));
        Item(m, "Store ChatGPT API key…", () => Credentials.AskAndStore("openai", "ChatGPT", "sk-"));
        Item(m, "Set Claude workspace id…", () =>
        {
            var v = Prompt.Ask("Claude workspace id",
                "Identity-linked API keys must name a workspace. Find it in " +
                "console.anthropic.com → Settings → Workspaces (wrkspc_…):", cfg.WorkspaceId ?? "");
            if (v == null) return;
            var t = v.Trim();
            Config.Set("anthropic_workspace_id", t.Length == 0 ? null : t);
            Hud.Show(t.Length == 0 ? "Workspace id cleared" : $"Workspace: {t}");
        });
    }

    void BuildDictationMenu(ToolStripItemCollection m, Config cfg)
    {
        var current = DictationKey.Current;
        var keyMenu = Sub(m, $"Dictation key ({DictationKey.Label(current)})");
        foreach (var k in Enum.GetValues<DictationKey.Choice>())
            Item(keyMenu.DropDownItems, DictationKey.Label(k), () =>
            {
                Config.Set("dictation_key", DictationKey.Id(k));
                dictation?.Restart();
                Hud.Show(k == DictationKey.Choice.Off ? "Dictation off" : $"Dictate: {DictationKey.Label(k)}");
            }, current == k);

        Item(m, "Clean up with Qwen", () =>
        {
            var now = !(new Config().Bool("dictation_cleanup") ?? true);
            Config.Set("dictation_cleanup", now);
            Hud.Show(now ? "Cleanup on" : "Cleanup off — raw transcript");
        }, cfg.Bool("dictation_cleanup") ?? true);
        Item(m, "Paste result (else copy)", () =>
            Config.Set("dictation_paste", !(new Config().Bool("dictation_paste") ?? true)),
            cfg.Bool("dictation_paste") ?? true);
        Item(m, "Edit dictionary…", () =>
        {
            if (!File.Exists(Paths.Dictionary))
                Paths.Write("# One term per line. The cleanup model spells these exactly.\n" +
                            "# Names, products, jargon — anything it keeps getting wrong.\n", Paths.Dictionary);
            Open(Paths.Dictionary);
        });
        m.Add(new ToolStripSeparator());
        Item(m, "Unload dictation models now", () =>
        {
            Daemon.Command("dictation_unload", boot: false);
            Hud.Show("Dictation models unloaded");
        });

        // Recent dictations: click one to put it back on the clipboard.
        m.Add(new ToolStripSeparator());
        var recent = Prefs.RecentDictations;
        if (recent.Count == 0)
        {
            Item(m, "No recent dictations", enabled: false);
            return;
        }
        Item(m, "Recent — click to copy", enabled: false);
        foreach (var entry in recent)
        {
            var item = Item(m, OneLine(entry.Text), () =>
            {
                Input.SetText(entry.Text);
                Hud.Show("Copied", 1);
            });
            item.ToolTipText = entry.Raw == null ? entry.Text : $"{entry.Text}\n\nBefore cleanup:\n{entry.Raw}";
        }
        Item(m, "Clear recent dictations", () =>
        {
            Prefs.ClearRecentDictations();
            Hud.Show("Recent dictations cleared", 1);
        });
    }

    // -- quit -----------------------------------------------------------------------------

    public void Quit()
    {
        Log.Write("quit requested");
        Foreground.Stop();
        Daemon.Quit();
        hotkeys?.Dispose();
        readyTimer.Stop();
        watcher?.Dispose();
        tldr.Cancel();
        dictation?.Dispose();
        reader.CloseReader();
        pill.HidePill();
        tray.Visible = false;
        tray.Dispose();
        // Give the quit request a moment to leave before the process ends.
        var t = new System.Windows.Forms.Timer { Interval = 300 };
        t.Tick += (_, _) => { t.Stop(); ExitThread(); };
        t.Start();
    }
}
