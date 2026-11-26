namespace BellowFlo;

static class Program
{
    [STAThread]
    static void Main()
    {
        // One copy per user session: two would both register the hotkeys
        // (the second fails) and both watch the dictation key.
        using var single = new Mutex(true, @"Local\BellowFlo", out bool first);
        if (!first) return;

        Application.SetHighDpiMode(HighDpiMode.PerMonitorV2);
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        Application.ThreadException += (_, e) => Log.Write($"unhandled: {e.Exception}");
        AppDomain.CurrentDomain.UnhandledException +=
            (_, e) => Log.Write($"fatal: {e.ExceptionObject}");

        Paths.EnsureDataDir();
        var coordinator = new Coordinator();
        coordinator.Start();
        Application.Run(coordinator);
    }
}
