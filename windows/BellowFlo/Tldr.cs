using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;

namespace BellowFlo;

/// Runs tldr.py. Cancellable, because a provider can take tens of seconds
/// and a wait you cannot call off reads as a hang.
sealed class Tldr
{
    Process? task;
    bool cancelled;
    public bool IsRunning => task != null;

    /// Short enough that summarising would hand back roughly what went in.
    public static bool TooShort(string text) =>
        Rsvp.Words(text).Length < new Config().TldrMinWords;

    /// `done(summary, error)`: a summary, or an error message to show. Both
    /// null means cancelled, say nothing. Called on the UI thread.
    public void Run(string text, Action<string?, string?> done)
    {
        if (task != null) return;
        var ui = SynchronizationContext.Current;
        var psi = new ProcessStartInfo(Paths.Python)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardInputEncoding = new UTF8Encoding(false),
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
            WorkingDirectory = Paths.EngineDir,
        };
        psi.ArgumentList.Add("-X");
        psi.ArgumentList.Add("utf8");
        psi.ArgumentList.Add(Paths.TldrScript);
        Process p;
        try
        {
            p = Process.Start(psi) ?? throw new InvalidOperationException("no process");
        }
        catch (Exception e)
        {
            done(null, e.Message);
            return;
        }
        task = p;
        cancelled = false;
        var stdout = p.StandardOutput.ReadToEndAsync();
        var stderr = p.StandardError.ReadToEndAsync();
        Task.Run(async () =>
        {
            try
            {
                await p.StandardInput.WriteAsync(text);
                p.StandardInput.Close();
            }
            catch (IOException) { }                  // it exited early; stderr says why
            await p.WaitForExitAsync();
            var outText = (await stdout).Trim();
            var errText = (await stderr).Trim();
            int code = p.ExitCode;
            void Finish()
            {
                task = null;
                p.Dispose();
                if (cancelled) done(null, null);
                else if (code == 0 && outText.Length > 0) done(outText, null);
                else done(null, errText.Length > 0 ? LastLine(errText) : "the summariser failed");
            }
            if (ui != null) ui.Post(_ => Finish(), null); else Finish();
        });
    }

    static string LastLine(string s) =>
        s.Split('\n', StringSplitOptions.RemoveEmptyEntries).LastOrDefault()?.Trim() ?? s;

    public void Cancel()
    {
        if (task == null) return;
        cancelled = true;
        try { task.Kill(entireProcessTree: true); }
        catch (Exception) { }
    }
}

/// Remembers summaries for a few minutes, so reading a summary and then
/// hearing it costs one provider call and gives identical wording.
static class SummaryCache
{
    static readonly TimeSpan Ttl = TimeSpan.FromMinutes(5);
    const int MaxEntries = 8;
    static readonly Dictionary<string, (string summary, DateTime at)> Entries = new();

    /// Settings that change the wording are part of the identity.
    static string Key(string text)
    {
        var cfg = new Config();
        var digest = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(text)));
        return string.Join("|", digest, cfg.TldrProvider, cfg.TldrModel ?? "", cfg.TldrSentences);
    }

    public static string? Lookup(string text)
    {
        Prune();
        return Entries.TryGetValue(Key(text), out var e) ? e.summary : null;
    }

    public static void Store(string summary, string text)
    {
        Entries[Key(text)] = (summary, DateTime.Now);
        Prune();
    }

    static void Prune()
    {
        var cutoff = DateTime.Now - Ttl;
        foreach (var k in Entries.Where(e => e.Value.at < cutoff).Select(e => e.Key).ToList())
            Entries.Remove(k);
        foreach (var k in Entries.OrderBy(e => e.Value.at).Take(Math.Max(0, Entries.Count - MaxEntries))
                                 .Select(e => e.Key).ToList())
            Entries.Remove(k);
    }
}
