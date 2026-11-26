using System.Text;

namespace BellowFlo;

/// Where the engine and the user's data live. Must agree with bf_paths.py,
/// because the agent hooks find the data folder without the app's help.
static class Paths
{
    /// The engine: the Python code and, in a source checkout, its venv.
    /// Never written to.
    public static readonly string EngineDir = FindEngine();

    /// Everything that changes: config, dictionary, the state and word files,
    /// staged text, the daemon's endpoint and log, model weights.
    public static readonly string DataDir = FindData();

    static string FindEngine()
    {
        var env = Environment.GetEnvironmentVariable("BELLOWFLO_ENGINE");
        if (!string.IsNullOrEmpty(env) && File.Exists(Path.Combine(env, "daemon.py")))
            return env;
        // An installed build ships the engine beside the exe.
        var beside = Path.Combine(AppContext.BaseDirectory, "engine");
        if (File.Exists(Path.Combine(beside, "daemon.py"))) return beside;
        // A source checkout: windows/BellowFlo/bin/<config>/<tfm>/ is a few
        // levels below the repo root, which holds kokoro/.
        for (var d = new DirectoryInfo(AppContext.BaseDirectory); d != null; d = d.Parent)
        {
            var k = Path.Combine(d.FullName, "kokoro");
            if (File.Exists(Path.Combine(k, "daemon.py"))) return k;
        }
        return beside;
    }

    static string FindData()
    {
        var env = Environment.GetEnvironmentVariable("BELLOWFLO_DATA");
        if (!string.IsNullOrEmpty(env)) return env;
        return Path.Combine(Environment.GetFolderPath(
            Environment.SpecialFolder.LocalApplicationData), "Bellow Flo");
    }

    /// The interpreter the daemon and tldr.py run under: BELLOWFLO_PYTHON,
    /// else the standalone runtime an installed build ships in
    /// engine\runtime, else a source checkout's venv.
    public static string Python
    {
        get
        {
            var env = Environment.GetEnvironmentVariable("BELLOWFLO_PYTHON");
            if (!string.IsNullOrEmpty(env)) return env;
            var runtime = Path.Combine(EngineDir, "runtime", "python.exe");
            if (File.Exists(runtime)) return runtime;
            return Path.Combine(EngineDir, "venv", "Scripts", "python.exe");
        }
    }

    public static string Data(string name) => Path.Combine(DataDir, name);

    public static string PortFile => Data("daemon.port");
    public static string State => Data("state");
    public static string Word => Data("word");
    public static string Pending => Data("pending.txt");
    public static string Selection => Data("selection.txt");
    public static string Config => Data("config.json");
    public static string Dictionary => Data("dictionary.txt");
    public static string Dictation => Data("dictation.wav");
    public static string DaemonLog => Data("daemon.log");
    public static string AppLog => Data("BellowFlo.log");
    public static string AppPrefs => Data("app.json");
    public static string DaemonScript => Path.Combine(EngineDir, "daemon.py");
    public static string TldrScript => Path.Combine(EngineDir, "tldr.py");

    /// Create the data folder and carry over files that used to live beside
    /// the engine. Copies, never moves, never overwrites.
    public static void EnsureDataDir()
    {
        Directory.CreateDirectory(Path.Combine(DataDir, "models"));
        foreach (var name in new[] { "config.json", "dictionary.txt", "notify_forward.json" })
        {
            var src = Path.Combine(EngineDir, name);
            var dst = Data(name);
            try
            {
                if (File.Exists(src) && !File.Exists(dst)) File.Copy(src, dst);
            }
            catch (IOException) { }
        }
    }

    static readonly UTF8Encoding Utf8 = new(false);

    /// Read without blocking the engine's writes. The daemon replaces these
    /// files with os.replace, which Windows refuses while anyone holds the
    /// file open without FILE_SHARE_DELETE, so every read here shares it.
    public static string Read(string path)
    {
        for (int attempt = 0; attempt < 5; attempt++)
        {
            try
            {
                using var fs = new FileStream(path, FileMode.Open, FileAccess.Read,
                                              FileShare.ReadWrite | FileShare.Delete);
                using var sr = new StreamReader(fs, Utf8, detectEncodingFromByteOrderMarks: true);
                return sr.ReadToEnd();
            }
            catch (FileNotFoundException) { return ""; }
            catch (DirectoryNotFoundException) { return ""; }
            catch (IOException) { Thread.Sleep(5); }
            catch (UnauthorizedAccessException) { Thread.Sleep(5); }
        }
        return "";
    }

    /// Write to a temporary file and swap it in, so a reader never sees half
    /// a file. Retries the swap for the same sharing reason as Read.
    public static bool Write(string text, string path)
    {
        var tmp = path + ".app.tmp";
        try
        {
            File.WriteAllText(tmp, text, Utf8);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            Log.Write($"write {Path.GetFileName(path)} failed: {e.Message}");
            return false;
        }
        for (int attempt = 0; attempt < 20; attempt++)
        {
            try
            {
                File.Move(tmp, path, overwrite: true);
                return true;
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                Thread.Sleep(10);
            }
        }
        Log.Write($"write {Path.GetFileName(path)} failed: file stayed locked");
        return false;
    }
}
