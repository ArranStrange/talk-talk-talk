using System.Runtime.InteropServices;
using static BellowFlo.Native;

namespace BellowFlo;

/// Watches the hold-to-dictate key with a low-level keyboard hook. Listen
/// only: every key is passed on untouched, so the hook can never swallow
/// typing.
///
/// The hook lives on its own thread with its own message loop. Windows
/// silently removes a low-level hook whose thread is slow to answer, and the
/// UI thread has legitimate pauses (opening the microphone, the clipboard),
/// so sharing it would let any of those switch dictation off unnoticed.
sealed class DictationKey : IDisposable
{
    public enum Choice { RightCtrl, RightAlt, CtrlWin, Off }

    public static string Label(Choice c) => c switch
    {
        Choice.RightCtrl => "Hold Right Ctrl",
        Choice.RightAlt => "Hold Right Alt",
        Choice.CtrlWin => "Hold Ctrl + Win",
        _ => "Off",
    };

    /// Stored in config.json as "dictation_key". The macOS app's values
    /// (rightOption, fn, …) mean nothing here and fall back to the default.
    public static string Id(Choice c) => c switch
    {
        Choice.RightCtrl => "rightCtrl",
        Choice.RightAlt => "rightAlt",
        Choice.CtrlWin => "ctrlWin",
        _ => "off",
    };

    public static Choice Current => new Config().Str("dictation_key") switch
    {
        "rightAlt" => Choice.RightAlt,
        "ctrlWin" => Choice.CtrlWin,
        "off" => Choice.Off,
        _ => Choice.RightCtrl,
    };

    const uint VK_LCONTROL = 0xA2, VK_RCONTROL = 0xA3, VK_RMENU = 0xA5,
               VK_LWIN = 0x5B, VK_RWIN = 0x5C;

    readonly LowLevelKeyboardProc proc;   // held so the GC cannot collect it under the hook
    readonly SynchronizationContext ui;
    Thread? thread;
    uint threadId;
    IntPtr hook;
    volatile Choice choice;
    // Touched only on the hook thread.
    bool lctrl, rctrl, lwin, rwin, ralt, chorded;
    // Also cleared from the UI thread (ForgetHold).
    volatile bool held;

    public event Action? Pressed;
    /// Another key went down during the hold: this is a shortcut, not
    /// dictation. Fired once, as soon as it is known.
    public event Action? Chorded;
    /// The argument is true when another key was pressed during the hold:
    /// the key was used as an ordinary modifier (Ctrl+C), not to dictate.
    public event Action<bool>? Released;

    public DictationKey()
    {
        proc = HookProc;
        ui = SynchronizationContext.Current ?? new WindowsFormsSynchronizationContext();
    }

    public bool Running => thread != null;

    public void Start()
    {
        choice = Current;
        if (thread != null || choice == Choice.Off) return;
        var ready = new ManualResetEventSlim();
        thread = new Thread(() =>
        {
            threadId = GetCurrentThreadId();
            hook = SetWindowsHookEx(WH_KEYBOARD_LL, proc, GetModuleHandle(null), 0);
            if (hook == IntPtr.Zero)
                Log.Write($"dictation: keyboard hook refused ({Marshal.GetLastWin32Error()})");
            ready.Set();
            if (hook == IntPtr.Zero) return;
            // Hook callbacks are delivered while this thread waits here.
            while (GetMessage(out var msg, IntPtr.Zero, 0, 0) > 0) { }
            UnhookWindowsHookEx(hook);
            hook = IntPtr.Zero;
        }) { IsBackground = true, Name = "dictation key" };
        thread.Start();
        ready.Wait(2000);
        if (hook != IntPtr.Zero) Log.Write($"dictation: watching {Label(choice)}");
        else thread = null;
    }

    public void Stop()
    {
        var t = thread;
        if (t == null) return;
        thread = null;
        PostThreadMessage(threadId, WM_QUIT, IntPtr.Zero, IntPtr.Zero);
        t.Join(1000);
        lctrl = rctrl = lwin = rwin = ralt = held = chorded = false;
    }

    public void Restart() { Stop(); Start(); }

    /// Asked directly of the keyboard rather than the hook, as a check for a
    /// key-up the hook never saw (released over an elevated window, or while
    /// Win+L had switched to the secure desktop).
    public bool PhysicallyHeld()
    {
        static bool Down(uint vk) => (GetAsyncKeyState((int)vk) & 0x8000) != 0;
        return choice switch
        {
            Choice.RightCtrl => Down(VK_RCONTROL),
            Choice.RightAlt => Down(VK_RMENU),
            Choice.CtrlWin => (Down(VK_LCONTROL) || Down(VK_RCONTROL)) && (Down(VK_LWIN) || Down(VK_RWIN)),
            _ => false,
        };
    }

    IntPtr HookProc(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0)
        {
            var k = Marshal.PtrToStructure<KBDLLHOOKSTRUCT>(lParam);
            // Our own SendInput (the paste, the menu mask) must not count.
            if ((k.flags & LLKHF_INJECTED) == 0)
            {
                int msg = (int)wParam;
                bool down = msg == WM_KEYDOWN || msg == WM_SYSKEYDOWN;
                bool up = msg == WM_KEYUP || msg == WM_SYSKEYUP;
                if (down || up) Track(k.vkCode, down);
            }
        }
        return CallNextHookEx(hook, nCode, wParam, lParam);
    }

    void Track(uint vk, bool down)
    {
        switch (vk)
        {
            case VK_LCONTROL: lctrl = down; break;
            case VK_RCONTROL: rctrl = down; break;
            case VK_LWIN: lwin = down; break;
            case VK_RWIN: rwin = down; break;
            case VK_RMENU: ralt = down; break;
            default:
                // Any other key while held makes this a shortcut, not dictation.
                if (down && held && !chorded)
                {
                    chorded = true;
                    ui.Post(_ => Chorded?.Invoke(), null);
                }
                return;
        }
        bool now = choice switch
        {
            Choice.RightCtrl => rctrl,
            Choice.RightAlt => ralt,
            Choice.CtrlWin => (lctrl || rctrl) && (lwin || rwin),
            _ => false,
        };
        if (now == held) return;          // key repeat, or the other half of a chord
        held = now;
        if (now)
        {
            chorded = false;
            if (choice is Choice.RightAlt or Choice.CtrlWin)
            {
                // Released on its own, Alt opens the menu bar and Win the
                // Start menu. A tap of an unassigned key in between makes the
                // release a chord, which does neither.
                Input.Tap(Input.VK_MASK);
            }
            ui.Post(_ => Pressed?.Invoke(), null);
        }
        else
        {
            var wasChord = chorded;
            ui.Post(_ => Released?.Invoke(wasChord), null);
        }
    }

    /// The UI side saw the key go up by other means; forget the hold.
    public void ForgetHold() => held = false;

    public void Dispose() => Stop();
}
