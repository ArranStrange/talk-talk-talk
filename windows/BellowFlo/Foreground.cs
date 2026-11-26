using System.Diagnostics;
using System.Text;
using static BellowFlo.Native;

namespace BellowFlo;

/// Keeps track of the last window the user was working in, and moves focus
/// on purpose.
///
/// Needed because clicking the tray icon makes the taskbar the foreground
/// window, and the menu takes it from there: by the time "Speak selection"
/// runs, a Ctrl+C would go to the taskbar, not the editor. macOS has no such
/// problem, because its menu bar never takes focus from the frontmost app.
static class Foreground
{
    static WinEventProc? proc;        // held so the GC cannot collect it under the hook
    static IntPtr hook;
    static readonly uint OwnPid = (uint)Environment.ProcessId;

    /// The last foreground window that belongs to neither us nor the shell.
    public static IntPtr LastWorkWindow { get; private set; }

    /// Call on the UI thread. Out-of-context events arrive through its
    /// message loop, so the callback runs there and needs no locking.
    public static void Start()
    {
        proc = (_, _, hwnd, _, _, _, _) => Seen(hwnd);
        hook = SetWinEventHook(EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND, IntPtr.Zero,
                               proc, 0, 0, WINEVENT_OUTOFCONTEXT);
        Seen(GetForegroundWindow());
    }

    public static void Stop()
    {
        if (hook != IntPtr.Zero) UnhookWinEvent(hook);
        hook = IntPtr.Zero;
    }

    static readonly HashSet<string> ShellClasses = new()
    {
        "Shell_TrayWnd", "Shell_SecondaryTrayWnd", "NotifyIconOverflowWindow",
        "TopLevelWindowForOverflowXamlIsland", "Progman", "WorkerW",
        "Windows.UI.Core.CoreWindow", "XamlExplorerHostIslandWindow",
    };

    static void Seen(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero) return;
        GetWindowThreadProcessId(hwnd, out var pid);
        if (pid == OwnPid) return;
        var cls = new StringBuilder(256);
        GetClassName(hwnd, cls, cls.Capacity);
        if (ShellClasses.Contains(cls.ToString())) return;
        LastWorkWindow = hwnd;
    }

    /// Put `hwnd` in front, using the input-attach workaround when Windows'
    /// foreground lock refuses a plain SetForegroundWindow. True if it took.
    public static bool Bring(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero || !IsWindow(hwnd)) return false;
        if (GetForegroundWindow() == hwnd) return true;
        if (SetForegroundWindow(hwnd) && GetForegroundWindow() == hwnd) return true;
        var fg = GetForegroundWindow();
        uint fgThread = GetWindowThreadProcessId(fg, out _);
        uint me = GetCurrentThreadId();
        bool attached = fgThread != 0 && fgThread != me && AttachThreadInput(me, fgThread, true);
        try
        {
            BringWindowToTop(hwnd);
            SetForegroundWindow(hwnd);
        }
        finally
        {
            if (attached) AttachThreadInput(me, fgThread, false);
        }
        return GetForegroundWindow() == hwnd;
    }

    /// Before copying the selection from a menu click: hand focus back to the
    /// window the user was in. False if it would not take focus, in which case
    /// a Ctrl+C would go somewhere else and must not be sent.
    public static async Task<bool> ReturnToWork()
    {
        var target = LastWorkWindow;
        if (target == IntPtr.Zero) return false;
        // The click handler runs inside the menu's modal loop. Let the menu
        // finish closing first: closing can hand activation back to the tray
        // icon's hidden window, which would undo a Bring done before it.
        await Task.Delay(80);
        var sw = Stopwatch.StartNew();
        Bring(target);
        while (GetForegroundWindow() != target && sw.ElapsedMilliseconds < 300) await Task.Delay(20);
        await Task.Delay(60);
        return GetForegroundWindow() == target;
    }
}
