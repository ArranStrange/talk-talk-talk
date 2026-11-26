using System.Collections.Concurrent;
using System.Diagnostics;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace BellowFlo;

/// Talks to the speech daemon. On Windows that is loopback TCP: the daemon
/// writes daemon.port as {"port": N, "token": "..."} and refuses any request
/// without the token (see bf_ipc.py). One JSON request, one JSON reply, per
/// connection.
///
/// Requests go through one background thread in order, as on macOS, so a
/// pause sent after a play cannot overtake it.
static class Daemon
{
    static readonly BlockingCollection<Action> Queue = new();
    static SynchronizationContext? ui;
    static readonly object StartGate = new();

    /// Call once on the UI thread, so replies can be handed back to it.
    public static void Init()
    {
        ui = SynchronizationContext.Current;
        var t = new Thread(() =>
        {
            foreach (var work in Queue.GetConsumingEnumerable())
            {
                try { work(); }
                catch (Exception e) { Log.Write($"daemon client: {e.Message}"); }
            }
        }) { IsBackground = true, Name = "daemon client" };
        t.Start();
    }

    // -- transport ------------------------------------------------------------

    static (int port, string token)? Endpoint()
    {
        try
        {
            var info = JsonNode.Parse(Paths.Read(Paths.PortFile));
            var port = info?["port"]?.GetValue<int>() ?? 0;
            var token = info?["token"]?.GetValue<string>() ?? "";
            return port > 0 ? (port, token) : null;
        }
        catch (Exception e) when (e is JsonException or InvalidOperationException or FormatException)
        {
            return null;
        }
    }

    static TcpClient? Connect((int port, string token) ep)
    {
        var c = new TcpClient { NoDelay = true };
        try
        {
            // Loopback refuses instantly when nothing listens; the timeout is
            // for the rare port taken by something that never answers.
            if (!c.ConnectAsync("127.0.0.1", ep.port).Wait(1000))
            {
                c.Dispose();
                return null;
            }
            return c;
        }
        catch (Exception)
        {
            c.Dispose();
            return null;
        }
    }

    static JsonObject? Exchange(TcpClient c, string token, JsonObject request, int timeoutMs)
    {
        var req = (JsonObject)request.DeepClone();
        req["token"] = token;
        var bytes = Encoding.UTF8.GetBytes(req.ToJsonString());
        using var stream = c.GetStream();
        c.ReceiveTimeout = timeoutMs;
        c.SendTimeout = 10000;
        stream.Write(bytes, 0, bytes.Length);
        c.Client.Shutdown(SocketShutdown.Send);
        using var all = new MemoryStream();
        var buf = new byte[65536];
        int n;
        while ((n = stream.Read(buf, 0, buf.Length)) > 0) all.Write(buf, 0, n);
        if (all.Length == 0) return null;
        try { return JsonNode.Parse(all.ToArray()) as JsonObject; }
        catch (JsonException) { return null; }
    }

    /// Is the thing on the port really our daemon? Something answering is not
    /// proof, so ask and expect our own reply shape.
    static bool Alive()
    {
        var ep = Endpoint();
        if (ep == null) return false;
        using var c = Connect(ep.Value);
        if (c == null) return false;
        try
        {
            var reply = Exchange(c, ep.Value.token, new JsonObject { ["cmd"] = "status" }, 2000);
            return reply?.ContainsKey("ok") == true;
        }
        catch (Exception) { return false; }
    }

    /// Start the daemon and wait for it to answer. Only called when a
    /// command needs a daemon that is not running.
    static bool StartDaemon()
    {
        lock (StartGate)
        {
            if (Alive()) return true;
            if (!File.Exists(Paths.Python))
            {
                Log.Write($"no Python at {Paths.Python}");
                Hud.Show("Speech engine not installed.\nRun the Bellow Flo installer again.", 5);
                return false;
            }
            var psi = new ProcessStartInfo(Paths.Python)
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                WorkingDirectory = Paths.EngineDir,
            };
            // -X utf8: the daemon's files and log must be UTF-8, and the
            // default code page cannot encode much of what gets spoken.
            // --log: we cannot hand it a file as stdout, so it opens its own.
            psi.ArgumentList.Add("-X");
            psi.ArgumentList.Add("utf8");
            psi.ArgumentList.Add(Paths.DaemonScript);
            psi.ArgumentList.Add("--log");
            Process? p;
            try
            {
                p = Process.Start(psi);
                Log.Write($"started daemon pid {p?.Id}");
            }
            catch (Exception e)
            {
                Log.Write($"could not start the daemon: {e.Message}");
                return false;
            }
            using (p)
            {
                // 30 s for a model load, or as long as the engine reports a
                // first-run model download, which can take minutes.
                var began = Stopwatch.StartNew();
                while (true)
                {
                    Thread.Sleep(100);
                    if (Alive()) return true;
                    if (p == null || p.HasExited)
                    {
                        Log.Write($"daemon exited ({p?.ExitCode}); see daemon.log");
                        return false;
                    }
                    bool downloading = Paths.Read(Paths.State).Trim() == "downloading";
                    if (began.Elapsed > (downloading ? TimeSpan.FromMinutes(30) : TimeSpan.FromSeconds(30))) break;
                }
            }
            Log.Write("daemon did not answer in time; see daemon.log");
            return false;
        }
    }

    /// Runs on the queue thread. Null means no daemon, or no parseable reply.
    static JsonObject? RoundTrip(JsonObject request, bool boot, int timeoutMs)
    {
        var ep = Endpoint();
        var c = ep == null ? null : Connect(ep.Value);
        if (c == null)
        {
            if (!boot || !StartDaemon()) return null;
            ep = Endpoint();
            c = ep == null ? null : Connect(ep.Value);
            if (c == null) return null;
        }
        using (c)
        {
            try { return Exchange(c, ep!.Value.token, request, timeoutMs); }
            catch (Exception e) when (e is IOException or SocketException or ObjectDisposedException)
            {
                Log.Write($"daemon {request["cmd"]}: {e.Message}");
                return null;
            }
        }
    }

    // -- API --------------------------------------------------------------------

    /// Fire and forget. `boot` is false for commands that should not bring a
    /// daemon up just to be told there is nothing to do.
    public static void Send(JsonObject request, bool boot = true)
    {
        Queue.Add(() =>
        {
            var reply = RoundTrip(request, boot, 10000);
            // A refused command used to fail silently, which is how "nothing
            // happens" bugs stay unexplained. Record it instead.
            if (reply?["ok"] is JsonValue ok && ok.TryGetValue<bool>(out var b) && !b)
                Log.Write($"daemon refused {request["cmd"]}: {reply["msg"]}");
        });
    }

    /// Send and hand the reply to `done` on the UI thread. The default
    /// timeout allows for a first dictation waiting on its model download.
    public static void Request(JsonObject request, Action<JsonObject?> done, bool boot = true,
                               int timeoutMs = 30 * 60 * 1000)
    {
        Queue.Add(() =>
        {
            JsonObject? reply = null;
            try { reply = RoundTrip(request, boot, timeoutMs); }
            finally
            {
                if (ui != null) ui.Post(_ => done(reply), null); else done(reply);
            }
        });
    }

    public static void Command(string cmd, bool boot = true) =>
        Send(new JsonObject { ["cmd"] = cmd }, boot);

    public static void Say(string text)
    {
        var cfg = new Config();
        // "align": with read-along on, the daemon refines word timing from
        // the synthesised audio instead of estimating it.
        Send(new JsonObject
        {
            ["cmd"] = "say", ["text"] = text, ["voice"] = cfg.Voice,
            ["speed"] = cfg.Speed, ["lang"] = cfg.Lang, ["align"] = Prefs.ReadAlong,
        });
    }

    public static void Back(double seconds = 10) =>
        Send(new JsonObject { ["cmd"] = "back", ["seconds"] = seconds });

    public static void Stop() => Command("stop", boot: false);
    public static void Quit() => Command("quit", boot: false);
    public static void Toggle() => Command("toggle");
    public static void Pause() => Command("pause", boot: false);
    public static void Resume() => Command("resume", boot: false);
}
