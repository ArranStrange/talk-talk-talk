using System.Drawing.Drawing2D;
using static BellowFlo.Native;

namespace BellowFlo;

/// Silent RSVP reader. Hold R to advance; nothing is spoken. Up/Down or
/// +/- change speed, Left/Right step a word, Esc closes.
sealed class Reader : Form
{
    static readonly Color Dim = Color.FromArgb(5, 5, 8);
    static readonly Color Accent = Color.FromArgb(217, 255, 92, 77);

    string[] words = Array.Empty<string>();
    int index;
    bool held;
    readonly System.Windows.Forms.Timer advance = new();
    readonly System.Windows.Forms.Timer chip = new() { Interval = 35 };
    DateTime chipShownAt;
    float chipAlpha;
    readonly List<Form> dimmers = new();
    IntPtr previous;

    public bool IsOpen => Visible;
    public (int at, int total) Position => (index + 1, words.Length);

    public Reader()
    {
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        TopMost = true;
        StartPosition = FormStartPosition.Manual;
        BackColor = Dim;
        Opacity = 0.94;
        DoubleBuffered = true;
        KeyPreview = true;
        advance.Tick += (_, _) => Advance();
        chip.Tick += (_, _) =>
        {
            var age = (DateTime.Now - chipShownAt).TotalSeconds;
            chipAlpha = age < 0.9 ? 1 : Math.Max(0, 1 - (float)(age - 0.9) / 0.42f);
            if (chipAlpha <= 0) chip.Stop();
            Invalidate();
        };
    }

    public void Open(string text)
    {
        var list = Rsvp.Words(text);
        if (list.Length == 0) { Hud.Show("Nothing to read"); return; }
        CloseReader();
        words = list;
        index = 0;
        previous = GetForegroundWindow();

        var active = Screen.FromPoint(Cursor.Position);
        // Dim the other displays too, so nothing bright pulls the eye away.
        foreach (var screen in Screen.AllScreens.Where(s => !s.Equals(active)))
        {
            var d = new DimForm { Bounds = screen.Bounds };
            d.Show();
            dimmers.Add(d);
        }
        Bounds = active.Bounds;
        Show();
        Activate();
        // The reader reads keys, so it must have focus. If Windows' foreground
        // lock refuses, holding R would type into the app underneath instead,
        // over the very selection being read. Better not to open at all.
        if (!Foreground.Bring(Handle))
        {
            Log.Write("reader: could not take focus");
            CloseReader();
            Hud.Show("Could not open the reader in front.\nClick the text and try again.", 3);
            return;
        }
        Invalidate();
    }

    public void CloseReader()
    {
        advance.Stop();
        chip.Stop();
        held = false;
        foreach (var d in dimmers) d.Close();
        dimmers.Clear();
        if (Visible)
        {
            Hide();
            // Hand focus back to whatever was in front before.
            if (previous != IntPtr.Zero) SetForegroundWindow(previous);
        }
        previous = IntPtr.Zero;
    }

    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        // Kept for reuse: hide instead of closing, unless the app is quitting.
        if (e.CloseReason == CloseReason.UserClosing)
        {
            e.Cancel = true;
            CloseReader();
        }
        base.OnFormClosing(e);
    }

    protected override void OnDeactivate(EventArgs e)
    {
        base.OnDeactivate(e);
        // R held while focus moved away never sends its key-up here.
        held = false;
        advance.Stop();
    }

    // -- keys ---------------------------------------------------------------------

    protected override void OnKeyDown(KeyEventArgs e)
    {
        e.Handled = e.SuppressKeyPress = true;
        switch (e.KeyCode)
        {
            case Keys.R:
                if (!held) { held = true; StartAdvancing(); }
                break;
            case Keys.Escape: CloseReader(); break;
            case Keys.Up: case Keys.Oemplus: case Keys.Add: ChangeSpeed(+25); break;
            case Keys.Down: case Keys.OemMinus: case Keys.Subtract: ChangeSpeed(-25); break;
            case Keys.Left: index = Math.Max(0, index - 1); Invalidate(); break;
            case Keys.Right: index = Math.Min(words.Length - 1, index + 1); Invalidate(); break;
            default: e.Handled = e.SuppressKeyPress = false; break;
        }
        base.OnKeyDown(e);
    }

    protected override void OnKeyUp(KeyEventArgs e)
    {
        if (e.KeyCode == Keys.R) { held = false; advance.Stop(); e.Handled = true; }
        base.OnKeyUp(e);
    }

    void ChangeSpeed(int delta)
    {
        Prefs.ReaderWpm = Math.Clamp(Prefs.ReaderWpm + delta, 100, 1200);
        chipShownAt = DateTime.Now;
        chipAlpha = 1;
        chip.Start();
        Invalidate();
    }

    // -- advancing ----------------------------------------------------------------

    /// Longer words dwell longer and punctuation earns a beat. The factors
    /// average near 1, so the stated WPM stays roughly honest.
    static double Delay(string word)
    {
        double b = 60.0 / Prefs.ReaderWpm;
        double length = Math.Clamp(0.7 + word.Length / 12.0, 0.7, 1.8);
        var t = word.TrimEnd('"', '\'', '”', '’');
        double punct = t.Length == 0 ? 1 : ".!?".Contains(t[^1]) ? 2.0 : ",;:".Contains(t[^1]) ? 1.4 : 1.0;
        return b * length * punct;
    }

    void StartAdvancing()
    {
        if (advance.Enabled || index >= words.Length - 1) return;
        Schedule();
    }

    void Schedule()
    {
        var next = Math.Min(index + 1, words.Length - 1);
        advance.Interval = Math.Max(1, (int)(Delay(words[next]) * 1000));
        advance.Start();
    }

    void Advance()
    {
        advance.Stop();
        if (!Visible || index >= words.Length - 1) return;
        index++;
        Invalidate();
        if (held) Schedule();
    }

    // -- drawing ------------------------------------------------------------------

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        float s = DeviceDpi / 96f;
        var f = ClientRectangle;
        float anchorX = f.Width * Rsvp.AnchorFraction, midY = f.Height / 2f;

        if (index < words.Length)
        {
            float size = 64 * s;
            float used = Rsvp.Draw(g, words[index], anchorX, midY - size * 0.62f, size, 20 * s,
                                   anchorX - 40 * s, f.Width - anchorX - 40 * s);
            using var guide = new SolidBrush(Color.FromArgb(77, 255, 255, 255));
            g.FillRectangle(guide, anchorX - 1 * s, midY - used * 0.95f, 2 * s, 14 * s);
            g.FillRectangle(guide, anchorX - 1 * s, midY + used * 0.62f, 2 * s, 14 * s);
        }

        using (var accent = new SolidBrush(Accent))
            g.FillRectangle(accent, 0, f.Height - 3 * s, f.Width * (index + 1f) / Math.Max(words.Length, 1), 3 * s);

        if (chipAlpha > 0)
        {
            float w = 116 * s, h = 34 * s;
            var r = new RectangleF((f.Width - w) / 2, f.Height - 110 * s, w, h);
            using var bg = new SolidBrush(Color.FromArgb((int)(217 * chipAlpha), 33, 33, 38));
            using var path = Hud.RoundedPath(r, 17 * s);
            g.FillPath(bg, path);
            using var fg = new SolidBrush(Color.FromArgb((int)(217 * chipAlpha), 255, 255, 255));
            using var font = new Font("Segoe UI", 14 * s, GraphicsUnit.Pixel);
            using var fmt = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center };
            g.DrawString($"{Prefs.ReaderWpm} wpm", font, fg, r, fmt);
        }
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing) { advance.Dispose(); chip.Dispose(); }
        base.Dispose(disposing);
    }

    /// A click-through dark layer over another display.
    sealed class DimForm : Form
    {
        public DimForm()
        {
            // Topmost through WS_EX_TOPMOST below, not TopMost = true, which
            // can activate the window despite ShowWithoutActivation.
            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            StartPosition = FormStartPosition.Manual;
            BackColor = Dim;
            Opacity = 0.94;
        }

        protected override bool ShowWithoutActivation => true;

        protected override CreateParams CreateParams
        {
            get
            {
                var cp = base.CreateParams;
                cp.ExStyle |= WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_TRANSPARENT | WS_EX_LAYERED | WS_EX_TOPMOST;
                return cp;
            }
        }
    }
}
