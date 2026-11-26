namespace BellowFlo;

/// Watches the data folder for the daemon's state and word files.
///
/// The daemon replaces them with os.replace, which shows up as a rename onto
/// the name, so renames count as well as writes. FileSystemWatcher can drop
/// events when its buffer overflows; a slow poll of the state file covers
/// that, and costs one small read a second.
sealed class StateWatcher : IDisposable
{
    readonly FileSystemWatcher fsw;
    readonly System.Windows.Forms.Timer poll;
    readonly SynchronizationContext ui;
    string lastState = "";

    public event Action? StateChanged;
    public event Action? WordChanged;

    public StateWatcher()
    {
        ui = SynchronizationContext.Current ?? new WindowsFormsSynchronizationContext();
        fsw = new FileSystemWatcher(Paths.DataDir)
        {
            NotifyFilter = NotifyFilters.FileName | NotifyFilters.LastWrite | NotifyFilters.Size,
            IncludeSubdirectories = false,
            InternalBufferSize = 64 * 1024,
        };
        fsw.Changed += (_, e) => Seen(e.Name);
        fsw.Created += (_, e) => Seen(e.Name);
        fsw.Renamed += (_, e) => Seen(e.Name);
        fsw.Error += (_, e) => Log.Write($"watcher: {e.GetException().Message}");

        poll = new System.Windows.Forms.Timer { Interval = 1000 };
        poll.Tick += (_, _) =>
        {
            var s = Paths.Read(Paths.State).Trim();
            if (s != lastState) { lastState = s; StateChanged?.Invoke(); }
        };
    }

    void Seen(string? name)
    {
        if (name == "state")
            ui.Post(_ => { lastState = Paths.Read(Paths.State).Trim(); StateChanged?.Invoke(); }, null);
        else if (name == "word")
            ui.Post(_ => WordChanged?.Invoke(), null);
    }

    public void Start()
    {
        lastState = Paths.Read(Paths.State).Trim();
        fsw.EnableRaisingEvents = true;
        poll.Start();
    }

    public void Dispose()
    {
        poll.Stop();
        poll.Dispose();
        fsw.EnableRaisingEvents = false;
        fsw.Dispose();
    }
}
