using System.Text;
using static BellowFlo.Native;

namespace BellowFlo;

/// Global hotkeys through RegisterHotKey: no hook, nothing to drop under
/// load, and Windows tells us if another app already owns a combination.
///
/// Ctrl+Alt is the counterpart of the Mac's ⌃⌥, but on many layouts Ctrl+Alt
/// is AltGr, which types letters (Polish AltGr+S is ś): registering those
/// would stop people typing them. So the modifiers are chosen from the
/// installed layouts (all of them, since people switch): the first of
/// Ctrl+Alt, Ctrl+Alt+Shift, Ctrl+Win under which none of our keys types a
/// character on any. "hotkey_modifiers" in config.json overrides it.
sealed class Hotkeys : NativeWindow, IDisposable
{
    readonly Dictionary<int, Action> actions = new();
    readonly List<string> failed = new();
    int nextId = 1;

    public uint Modifiers { get; }
    public string Prefix { get; }

    public Hotkeys(IEnumerable<Keys> keys)
    {
        CreateHandle(new CreateParams());
        (Modifiers, Prefix) = Choose(keys.ToList());
    }

    public int Count => actions.Count;
    public IReadOnlyList<string> Failed => failed;

    static readonly (string id, uint mods, string label)[] Candidates =
    {
        ("ctrl+alt", MOD_CONTROL | MOD_ALT, "Ctrl+Alt+"),
        ("ctrl+alt+shift", MOD_CONTROL | MOD_ALT | MOD_SHIFT, "Ctrl+Alt+Shift+"),
        ("ctrl+win", MOD_CONTROL | MOD_WIN, "Ctrl+Win+"),
    };

    static (uint, string) Choose(List<Keys> keys)
    {
        var wanted = new Config().Str("hotkey_modifiers");
        foreach (var c in Candidates)
            if (c.id == wanted) return (c.mods, c.label);
        var layouts = new IntPtr[Math.Max(1, GetKeyboardLayoutList(0, null))];
        int n = GetKeyboardLayoutList(layouts.Length, layouts);
        if (n <= 0) layouts = new[] { GetKeyboardLayout(0) };
        else layouts = layouts.Take(n).ToArray();
        foreach (var c in Candidates)
        {
            var clash = keys.FirstOrDefault(k => layouts.Any(l => Types(k, c.mods, l)));
            if (clash == Keys.None) return (c.mods, c.label);
            Log.Write($"hotkeys: {c.label}{clash} types a character on an installed layout; trying the next");
        }
        return (Candidates[^1].mods, Candidates[^1].label);
    }

    /// Does this key, with these modifiers held, type something?
    static bool Types(Keys key, uint mods, IntPtr layout)
    {
        if ((mods & MOD_ALT) == 0) return false;          // only AltGr layouts type with Ctrl+Alt
        var state = new byte[256];
        const byte down = 0x80;
        state[0x11] = state[0xA2] = down;                  // VK_CONTROL, VK_LCONTROL
        state[0x12] = state[0xA5] = down;                  // VK_MENU, VK_RMENU (AltGr)
        if ((mods & MOD_SHIFT) != 0) state[0x10] = state[0xA0] = down;
        var buf = new StringBuilder(8);
        uint scan = MapVirtualKeyEx((uint)key, 0, layout);  // MAPVK_VK_TO_VSC
        // Flag 4: leave the keyboard's dead-key state alone (Windows 10 1607+).
        int n = ToUnicodeEx((uint)key, scan, state, buf, buf.Capacity, 4, layout);
        if (n < 0) return true;                             // a dead key: AltGr+key composes
        return n > 0 && buf.ToString(0, n).Any(ch => !char.IsControl(ch));
    }

    public void Bind(Keys key, string name, Action action)
    {
        int id = nextId++;
        if (RegisterHotKey(Handle, id, Modifiers | MOD_NOREPEAT, (uint)key))
            actions[id] = action;
        else
            failed.Add(Prefix + name);
    }

    protected override void WndProc(ref Message m)
    {
        if (m.Msg == WM_HOTKEY && actions.TryGetValue((int)m.WParam, out var act))
        {
            try { act(); }
            catch (Exception e) { Log.Write($"hotkey: {e}"); }
            return;
        }
        base.WndProc(ref m);
    }

    public void Dispose()
    {
        foreach (var id in actions.Keys) UnregisterHotKey(Handle, id);
        actions.Clear();
        DestroyHandle();
    }
}
