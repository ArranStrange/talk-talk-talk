using System.Diagnostics;
using System.Runtime.InteropServices;
using static BellowFlo.Native;

namespace BellowFlo;

/// Synthetic keystrokes and the clipboard: how the selection is read
/// (copy it) and how dictation lands (paste it).
static class Input
{
    const ushort VK_CONTROL = 0x11, VK_SHIFT = 0x10, VK_MENU = 0x12,
                 VK_LWIN = 0x5B, VK_RWIN = 0x5C;
    public const ushort VK_C = 0x43, VK_V = 0x56;
    /// Unassigned virtual key. Tapping it while Alt or Win is down stops
    /// their release from opening the menu bar or the Start menu.
    public const ushort VK_MASK = 0xE8;

    static INPUT Key(ushort vk, bool up) => new()
    {
        type = INPUT_KEYBOARD,
        U = new InputUnion { ki = new KEYBDINPUT { wVk = vk, dwFlags = up ? KEYEVENTF_KEYUP : 0 } },
    };

    public static void Tap(ushort vk)
    {
        var inputs = new[] { Key(vk, false), Key(vk, true) };
        SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<INPUT>());
    }

    /// Ctrl+<key>, as one atomic batch so nothing interleaves.
    public static void Ctrl(ushort vk)
    {
        var inputs = new[]
        {
            Key(VK_CONTROL, false), Key(vk, false), Key(vk, true), Key(VK_CONTROL, true),
        };
        SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<INPUT>());
    }

    static bool Down(int vk) => (GetAsyncKeyState(vk) & 0x8000) != 0;

    public static bool ModifiersDown =>
        Down(VK_CONTROL) || Down(VK_SHIFT) || Down(VK_MENU) || Down(VK_LWIN) || Down(VK_RWIN);

    /// A hotkey fires while Ctrl+Alt are still held, and a Ctrl+C sent then
    /// would arrive as Ctrl+Alt+C. Wait for the hand to come off the keys.
    public static async Task WaitForModifiersReleased(int maxMs = 1500)
    {
        var sw = Stopwatch.StartNew();
        while (ModifiersDown && sw.ElapsedMilliseconds < maxMs) await Task.Delay(15);
    }

    // -- clipboard (UI thread only: the clipboard needs an STA thread) ----------

    public static string? GetText()
    {
        for (int i = 0; i < 5; i++)
        {
            try { return Clipboard.ContainsText() ? Clipboard.GetText() : null; }
            catch (ExternalException) { Thread.Sleep(20); }
        }
        return null;
    }

    public static bool SetText(string text)
    {
        if (string.IsNullOrEmpty(text)) return false;
        try
        {
            // copy: true keeps it after we exit; the retries ride out another
            // app holding the clipboard open for a moment.
            Clipboard.SetDataObject(text, true, 10, 30);
            return true;
        }
        catch (ExternalException e)
        {
            Log.Write($"clipboard busy: {e.Message}");
            return false;
        }
    }

    public static uint ClipboardSequence => GetClipboardSequenceNumber();

    /// Copy the selection in the foreground app and return it, putting back
    /// what the clipboard held before. Null when nothing was selected.
    public static async Task<string?> CopySelection()
    {
        await WaitForModifiersReleased();
        var before = GetText();
        var seq = ClipboardSequence;
        Ctrl(VK_C);
        // Up to 600 ms for the app to service the copy; most take ~50.
        var sw = Stopwatch.StartNew();
        while (ClipboardSequence == seq && sw.ElapsedMilliseconds < 600) await Task.Delay(20);
        if (ClipboardSequence == seq) return null;
        await Task.Delay(30);                    // let the owner finish writing every format
        var selection = GetText();
        if (before != null) SetText(before);
        return string.IsNullOrEmpty(selection) ? null : selection;
    }

    /// Put text where the cursor is, then give the clipboard back.
    public static async Task Paste(string text)
    {
        await WaitForModifiersReleased();
        var previous = GetText();
        if (!SetText(text)) return;
        Ctrl(VK_V);
        await Task.Delay(600);
        if (previous != null && GetText() == text) SetText(previous);
    }
}
