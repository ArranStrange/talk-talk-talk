using System.Drawing.Drawing2D;

namespace BellowFlo;

/// Colours, labels and the waveform mark, kept the same as the macOS app.
static class Look
{
    static Color C(double r, double g, double b) =>
        Color.FromArgb((int)(r * 255), (int)(g * 255), (int)(b * 255));

    /// The tray mark's colour per state.
    public static readonly Dictionary<string, Color> Tray = new()
    {
        ["idle"] = C(0.55, 0.55, 0.55),
        ["summarising"] = C(0.62, 0.45, 0.95),
        ["loading"] = C(0.95, 0.60, 0.10),
        ["synthesizing"] = C(0.95, 0.60, 0.10),
        ["playing"] = C(0.20, 0.72, 0.32),
        ["paused"] = C(0.90, 0.75, 0.10),
        ["ready"] = C(0.30, 0.50, 0.95),
        ["listening"] = C(0.95, 0.30, 0.30),
        ["transcribing"] = C(0.95, 0.60, 0.10),
        ["downloading"] = C(0.95, 0.60, 0.10),
    };

    /// The pill's mark, a touch brighter on its dark ground.
    public static readonly Dictionary<string, Color> Dot = new()
    {
        ["loading"] = C(0.95, 0.60, 0.10),
        ["synthesizing"] = C(0.95, 0.60, 0.10),
        ["playing"] = C(0.25, 0.80, 0.35),
        ["paused"] = C(0.95, 0.85, 0.20),
        ["ready"] = C(0.35, 0.55, 0.95),
        ["summarising"] = C(0.62, 0.45, 0.95),
        ["listening"] = C(0.95, 0.30, 0.30),
        ["transcribing"] = C(0.95, 0.60, 0.10),
        ["downloading"] = C(0.95, 0.60, 0.10),
    };

    public static readonly Dictionary<string, string> PillLabel = new()
    {
        ["downloading"] = "Downloading voices…",
        ["loading"] = "Loading model…", ["synthesizing"] = "Preparing…",
        ["playing"] = "Speaking", ["paused"] = "Paused",
        ["ready"] = "Agent replied", ["summarising"] = "Summarising…",
        ["listening"] = "Listening…", ["transcribing"] = "Transcribing…",
    };

    public static readonly Dictionary<string, string> MenuLabel = new()
    {
        ["idle"] = "Idle", ["loading"] = "Loading model…", ["synthesizing"] = "Preparing…",
        ["playing"] = "Speaking", ["paused"] = "Paused", ["ready"] = "Reply ready",
        ["summarising"] = "Summarising…", ["listening"] = "Listening…",
        ["transcribing"] = "Transcribing…", ["downloading"] = "Downloading voices (first run)…",
    };

    public static readonly Color On = Color.FromArgb(242, 64, 204, 89);
    public static readonly Color Off = Color.FromArgb(77, 255, 255, 255);
    public static readonly Color Bar = Color.FromArgb(242, 64, 204, 89);
    public static readonly Color Ground = Color.FromArgb(235, 20, 20, 26);

    /// The waveform mark: five rounded bars, tallest in the middle.
    public static void DrawMark(Graphics g, RectangleF box, Color color)
    {
        float[] heights = { 0.38f, 0.70f, 1f, 0.70f, 0.38f };
        float gap = box.Width / 5f;
        float bw = gap * 0.62f;
        using var brush = new SolidBrush(color);
        var smoothing = g.SmoothingMode;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        for (int i = 0; i < 5; i++)
        {
            float h = box.Height * heights[i];
            var r = new RectangleF(box.Left + i * gap + (gap - bw) / 2,
                                   box.Top + (box.Height - h) / 2, bw, h);
            using var path = Hud.RoundedPath(r, Math.Min(bw, h) / 2 - 0.01f);
            g.FillPath(brush, path);
        }
        g.SmoothingMode = smoothing;
    }

    static readonly Dictionary<(Color, int), Icon> Icons = new();

    /// A tray icon of the mark in a state colour. Cached: the state changes
    /// often and every icon is a GDI handle.
    public static Icon TrayIcon(string state, int size)
    {
        var color = Tray.TryGetValue(state, out var c) ? c : Tray["idle"];
        if (Icons.TryGetValue((color, size), out var cached)) return cached;
        using var bmp = new Bitmap(size, size);
        using (var g = Graphics.FromImage(bmp))
        {
            g.Clear(Color.Transparent);
            float pad = size * 0.06f;
            DrawMark(g, new RectangleF(pad, pad, size - 2 * pad, size - 2 * pad), color);
        }
        var h = bmp.GetHicon();
        var icon = (Icon)Icon.FromHandle(h).Clone();
        Native.DestroyIcon(h);
        Icons[(color, size)] = icon;
        return icon;
    }
}
