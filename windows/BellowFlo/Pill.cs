using System.Drawing.Drawing2D;
using System.Drawing.Text;
using static BellowFlo.Native;

namespace BellowFlo;

enum PillHit { Bg, Auto, Tldr, Back, Toggle, Stop, Rsvp, Close }

/// The floating status pill: state, the speech controls, and the read-along
/// drawer. Never takes focus, so clicking it leaves the cursor where it was.
/// Geometry is in the macOS app's points, scaled by the monitor's DPI.
sealed class Pill : Form
{
    public const int PillHeight = 36, DrawerHeight = 92, BarCount = 5;

    string state = "idle";
    bool autoRead, tldrOn, readAlong;
    string word = "";
    float[] waveHeights = { 8, 8, 8, 8, 8 };
    readonly List<(PillHit hit, RectangleF r)> hits = new();
    RectangleF labelRect;
    bool drawerOpen;
    float logicalWidth = 272;
    readonly System.Windows.Forms.Timer waveTimer = new() { Interval = 120 };
    readonly System.Windows.Forms.Timer wordTimer = new() { Interval = 100 };
    readonly System.Windows.Forms.Timer idleHide = new() { Interval = 10000 };
    readonly Random random = new();

    /// ✕ was clicked: stay away until something genuinely new happens.
    public bool Dismissed;
    public event Action<PillHit>? Hit;

    public Pill()
    {
        // Topmost through WS_EX_TOPMOST in CreateParams, not TopMost = true,
        // which can activate the window despite ShowWithoutActivation.
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.Manual;
        BackColor = Color.FromArgb(20, 20, 26);
        DoubleBuffered = true;
        Opacity = 0.94;
        waveTimer.Tick += (_, _) =>
        {
            for (int i = 0; i < BarCount; i++) waveHeights[i] = 5 + (float)random.NextDouble() * 19;
            Invalidate(Px(new RectangleF(38, 4, 44, 28)));
        };
        wordTimer.Tick += (_, _) => WordFileChanged();
        idleHide.Tick += (_, _) => { idleHide.Stop(); HidePill(); };
    }

    protected override bool ShowWithoutActivation => true;

    protected override CreateParams CreateParams
    {
        get
        {
            var cp = base.CreateParams;
            cp.ExStyle |= WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_TOPMOST;
            return cp;
        }
    }

    protected override void WndProc(ref Message m)
    {
        // Clicking must not pull focus out of the app being typed in.
        if (m.Msg == WM_MOUSEACTIVATE) { m.Result = (IntPtr)MA_NOACTIVATE; return; }
        base.WndProc(ref m);
    }

    float S => DeviceDpi / 96f;
    Rectangle Px(RectangleF r) => Rectangle.Round(new RectangleF(r.X * S, r.Y * S, r.Width * S, r.Height * S));

    // -- layout -------------------------------------------------------------------

    /// The size the pill wants, and the button rects for hit testing.
    SizeF ComputeLayout()
    {
        float labelWidth = state == "playing"
            ? 46
            : (float)Math.Floor((Look.PillLabel.TryGetValue(state, out var l) ? l : state).Length * 7.2) + 8;
        float autoX = 36 + labelWidth + 4, tldrX = autoX + 46, backX = tldrX + 48,
              togX = backX + 30, stopX = togX + 32, rsvpX = stopX + 30, closeX = rsvpX + 22;
        float w = closeX + 22 + 8;
        labelRect = new RectangleF(36, 8, labelWidth, 20);
        hits.Clear();
        hits.Add((PillHit.Auto, new RectangleF(autoX, 11, 42, 16)));
        hits.Add((PillHit.Tldr, new RectangleF(tldrX, 11, 44, 16)));
        hits.Add((PillHit.Back, new RectangleF(backX, 6, 30, 26)));
        hits.Add((PillHit.Toggle, new RectangleF(togX, 5, 32, 26)));
        hits.Add((PillHit.Stop, new RectangleF(stopX, 5, 32, 26)));
        hits.Add((PillHit.Rsvp, new RectangleF(rsvpX, 7, 22, 22)));
        hits.Add((PillHit.Close, new RectangleF(closeX, 8, 22, 20)));
        drawerOpen = readAlong && (state == "playing" || state == "paused");
        return new SizeF(w, drawerOpen ? DrawerHeight : PillHeight);
    }

    RectangleF Rect(PillHit h) => hits.FirstOrDefault(x => x.hit == h).r;

    /// Right edge stays put as the width changes; the drawer grows downward.
    void Fit(SizeF logical, Point? topRight = null)
    {
        logicalWidth = logical.Width;
        int w = (int)Math.Ceiling(logical.Width * S), h = (int)Math.Ceiling(logical.Height * S);
        var tr = topRight ?? new Point(Right, Top);
        if (Width != w || Height != h || topRight != null)
            Bounds = new Rectangle(tr.X - w, tr.Y, w, h);
        Region = Hud.Rounded(new Rectangle(0, 0, w, h), (int)(18 * S));
    }

    static Point DefaultTopRight()
    {
        var wa = Screen.FromPoint(Cursor.Position).WorkingArea;
        return new Point(wa.Right - 14, wa.Top + 10);
    }

    static Point StartTopRight()
    {
        if (Prefs.PillAnchor is Point a && Screen.AllScreens.Any(s => s.Bounds.Contains(a.X - 1, a.Y)))
            return a;
        return DefaultTopRight();
    }

    bool placed;

    // -- state --------------------------------------------------------------------

    public void UpdateState(string newState, bool autoRead, bool tldrOn, bool readAlong)
    {
        idleHide.Stop();
        state = newState;
        this.autoRead = autoRead;
        this.tldrOn = tldrOn;
        this.readAlong = readAlong;
        var size = ComputeLayout();
        if (!placed)
        {
            // Create the window where it will live first, so DeviceDpi is
            // that monitor's scaling rather than the primary's.
            var tr = StartTopRight();
            Bounds = new Rectangle(tr.X - 10, tr.Y, 10, 10);
            if (!IsHandleCreated) CreateHandle();
            Fit(ComputeLayout(), tr);
            placed = true;
        }
        else Fit(size);

        if (state == "playing") waveTimer.Start(); else waveTimer.Stop();
        if (drawerOpen) { wordTimer.Start(); WordFileChanged(); } else { wordTimer.Stop(); lastWord = null; }
        Invalidate();
        ShowPill();
    }

    public void ShowPill()
    {
        if (Dismissed) return;
        if (!Visible) Show();
    }

    public void HidePill()
    {
        waveTimer.Stop();
        wordTimer.Stop();
        lastWord = null;
        if (Visible) Hide();
    }

    /// Recovery for a pill dragged off-screen or onto a display that has
    /// since gone: forget the saved place and show it at the top right.
    public void BringToFront(string currentState, bool autoRead, bool tldrOn, bool readAlong)
    {
        Dismissed = false;
        state = currentState;
        this.autoRead = autoRead; this.tldrOn = tldrOn; this.readAlong = readAlong;
        var tr = DefaultTopRight();
        if (!IsHandleCreated) { Bounds = new Rectangle(tr.X - 10, tr.Y, 10, 10); CreateHandle(); }
        Fit(ComputeLayout(), tr);
        placed = true;
        Prefs.PillAnchor = tr;
        Invalidate();
        if (!Visible) Show();
        if (currentState == "idle") idleHide.Start();   // long enough to find once the menu shuts
        Hud.Show("Pill is at the top right", 2);
    }

    /// Saved when a drag ends (the caption drag's modal loop ends with
    /// WM_EXITSIZEMOVE), not on every WM_MOVE along the way.
    protected override void OnResizeEnd(EventArgs e)
    {
        base.OnResizeEnd(e);
        if (Visible && placed) Prefs.PillAnchor = new Point(Right, Top);
    }

    protected override void OnDpiChanged(DpiChangedEventArgs e)
    {
        base.OnDpiChanged(e);
        Fit(ComputeLayout());
        Invalidate();
    }

    string? lastWord;

    /// Read the published word and redraw the drawer if it changed.
    public void WordFileChanged()
    {
        if (!drawerOpen || !Visible) return;
        var w = Paths.Read(Paths.Word).Trim();
        if (w == lastWord) return;
        lastWord = w;
        word = w;
        Invalidate(Px(new RectangleF(0, PillHeight, logicalWidth, DrawerHeight - PillHeight)));
    }

    // -- mouse --------------------------------------------------------------------

    protected override void OnMouseDown(MouseEventArgs e)
    {
        base.OnMouseDown(e);
        if (e.Button != MouseButtons.Left) return;
        var p = new PointF(e.X / S, e.Y / S);
        foreach (var (hit, r) in hits)
        {
            if (!r.Contains(p)) continue;
            if (hit == PillHit.Close) { Dismissed = true; HidePill(); }
            else Hit?.Invoke(hit);
            return;
        }
        // Anywhere else drags the pill.
        ReleaseCapture();
        SendMessage(Handle, WM_NCLBUTTONDOWN, (IntPtr)HTCAPTION, IntPtr.Zero);
    }

    // -- drawing ------------------------------------------------------------------

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
        g.ScaleTransform(S, S);

        var markColor = Look.Dot.TryGetValue(state, out var dc) ? dc : Look.Dot["playing"];
        Look.DrawMark(g, new RectangleF(21 - 8, 18 - 7.5f, 16, 15), markColor);

        if (state == "playing")
        {
            using var bar = new SolidBrush(Look.Bar);
            for (int i = 0; i < BarCount; i++)
            {
                float bh = waveHeights[i];
                using var path = Hud.RoundedPath(new RectangleF(40 + i * 8, 18 - bh / 2, 4.5f, bh), 2);
                g.FillPath(bar, path);
            }
        }
        else
        {
            Label(g, Look.PillLabel.TryGetValue(state, out var l) ? l : state, labelRect, 13,
                 Color.FromArgb(242, 255, 255, 255), center: false);
        }

        bool speaking = state == "playing" || state == "paused";
        bool controls = speaking || state == "ready";
        Label(g, "AUTO", Rect(PillHit.Auto), 11, autoRead ? Look.On : Look.Off);
        Label(g, "TL;DR", Rect(PillHit.Tldr), 10, tldrOn ? Look.On : Look.Off);
        Label(g, "⏪", Rect(PillHit.Back), 16, White(speaking ? 242 : 64), symbol: true);
        Label(g, state is "paused" or "ready" ? "▶" : "⏸", Rect(PillHit.Toggle), 16,
             White(controls ? 242 : 64), symbol: true);
        Label(g, "⏹", Rect(PillHit.Stop), 16, White(state != "loading" ? 242 : 64), symbol: true);
        Label(g, "▾", Rect(PillHit.Rsvp), 14, readAlong ? Look.On : Look.Off, symbol: true);
        Label(g, "✕", Rect(PillHit.Close), 12, White(115), symbol: true);

        if (drawerOpen && word.Length > 0)
        {
            float left = 14, right = logicalWidth - 14, top = 46;
            float anchorX = left + (right - left) * Rsvp.AnchorFraction;
            Rsvp.Draw(g, word, anchorX, top - 4, 26, 12, anchorX - left, right - anchorX,
                      dimmed: state == "paused");
            using var tick = new SolidBrush(White(64));
            g.FillRectangle(tick, anchorX - 0.75f, top - 7, 1.5f, 6);
            g.FillRectangle(tick, anchorX - 0.75f, top + 36, 1.5f, 6);
        }
    }

    static Color White(int alpha) => Color.FromArgb(alpha, 255, 255, 255);

    static readonly Dictionary<(float, bool), Font> Fonts = new();

    static Font FontFor(float px, bool symbol)
    {
        if (Fonts.TryGetValue((px, symbol), out var f)) return f;
        f = new Font(symbol ? "Segoe UI Symbol" : "Segoe UI", px, GraphicsUnit.Pixel);
        Fonts[(px, symbol)] = f;
        return f;
    }

    static void Label(Graphics g, string text, RectangleF r, float px, Color color,
                     bool center = true, bool symbol = false)
    {
        using var brush = new SolidBrush(color);
        using var fmt = new StringFormat
        {
            Alignment = center ? StringAlignment.Center : StringAlignment.Near,
            LineAlignment = StringAlignment.Center,
            FormatFlags = StringFormatFlags.NoWrap,
            Trimming = StringTrimming.None,
        };
        g.DrawString(text, FontFor(px, symbol), brush, r, fmt);
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing) { waveTimer.Dispose(); wordTimer.Dispose(); idleHide.Dispose(); }
        base.Dispose(disposing);
    }
}
