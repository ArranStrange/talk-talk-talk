using System.Drawing.Drawing2D;
using static BellowFlo.Native;

namespace BellowFlo;

/// A centred, self-dismissing message. Click-through and never takes focus,
/// so it cannot interrupt typing.
sealed class Hud : Form
{
    static Hud? current;
    static SynchronizationContext? ui;

    public static void Init() => ui = SynchronizationContext.Current;

    /// Safe from any thread.
    public static void Show(string message, double seconds = 1.6)
    {
        if (ui != null && SynchronizationContext.Current != ui)
        {
            ui.Post(_ => Present(message, seconds), null);
            return;
        }
        Present(message, seconds);
    }

    static void Present(string message, double seconds)
    {
        current?.Close();
        current = new Hud(message, seconds);
        current.Show();
    }

    readonly string text;
    readonly System.Windows.Forms.Timer timer = new() { Interval = 15 };
    readonly DateTime until;
    bool fadingIn = true;

    Hud(string message, double seconds)
    {
        text = message;
        until = DateTime.Now.AddSeconds(seconds);
        // Topmost through WS_EX_TOPMOST in CreateParams, not TopMost = true,
        // which can activate the window: a HUD shown just before a paste
        // must never take the keystroke.
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.Manual;
        BackColor = Color.FromArgb(32, 32, 36);
        ForeColor = Color.White;
        Font = new Font("Segoe UI", 11f, FontStyle.Regular);
        Opacity = 0;
        DoubleBuffered = true;

        // Create the window on the target screen first, so DeviceDpi is that
        // monitor's scaling rather than the primary's.
        var screen = Screen.FromPoint(Cursor.Position).Bounds;
        Bounds = new Rectangle(screen.Left + screen.Width / 2, screen.Top + screen.Height / 2, 10, 10);
        CreateHandle();
        float s = DeviceDpi / 96f;
        var max = (int)(460 * s);
        var size = TextRenderer.MeasureText(text, Font, new Size(max, 0), TextFormatFlags.WordBreak);
        var w = Math.Min(Math.Max(size.Width + (int)(40 * s), (int)(150 * s)), (int)(500 * s));
        var h = size.Height + (int)(28 * s);
        Bounds = new Rectangle(screen.Left + (screen.Width - w) / 2,
                               screen.Top + (int)(screen.Height * 0.72), w, h);
        Region = Rounded(new Rectangle(0, 0, w, h), (int)(14 * s));

        timer.Tick += (_, _) => Step();
        timer.Start();
    }

    protected override bool ShowWithoutActivation => true;

    protected override CreateParams CreateParams
    {
        get
        {
            var cp = base.CreateParams;
            cp.ExStyle |= WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_TOPMOST | WS_EX_TRANSPARENT;
            return cp;
        }
    }

    void Step()
    {
        if (fadingIn)
        {
            Opacity = Math.Min(0.94, Opacity + 0.12);
            if (Opacity >= 0.94) fadingIn = false;
        }
        else if (DateTime.Now > until)
        {
            Opacity -= 0.05;
            if (Opacity <= 0.02)
            {
                timer.Stop();
                Close();
                if (current == this) current = null;
            }
        }
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var r = ClientRectangle;
        r.Inflate(-(int)(20 * DeviceDpi / 96f), 0);
        TextRenderer.DrawText(e.Graphics, text, Font, r, ForeColor,
            TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.WordBreak);
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing) timer.Dispose();
        base.Dispose(disposing);
    }

    public static Region Rounded(Rectangle r, int radius)
    {
        using var path = RoundedPath(r, radius);
        return new Region(path);
    }

    public static GraphicsPath RoundedPath(RectangleF r, float radius)
    {
        var d = radius * 2;
        var p = new GraphicsPath();
        p.AddArc(r.Left, r.Top, d, d, 180, 90);
        p.AddArc(r.Right - d, r.Top, d, d, 270, 90);
        p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        p.AddArc(r.Left, r.Bottom - d, d, d, 90, 90);
        p.CloseFigure();
        return p;
    }
}
