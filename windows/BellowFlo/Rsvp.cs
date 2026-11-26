namespace BellowFlo;

/// Shared RSVP maths: which letter the eye lands on, and how wide text is.
/// Used by the pill's read-along drawer and the full-screen reader, so the
/// anchor sits in the same place in each.
static class Rsvp
{
    public const string FontFamily = "Segoe UI";
    public static readonly Color OrpColor = Color.FromArgb(255, 92, 77);
    public const float AnchorFraction = 0.42f;

    /// Spritz-style pivot, 1-indexed.
    public static int OrpIndex(int length) => length switch
    {
        <= 1 => 1,
        <= 5 => 2,
        <= 9 => 3,
        <= 13 => 4,
        _ => 5,
    };

    static readonly Dictionary<float, Font> Fonts = new();

    public static Font Font(float px)
    {
        if (Fonts.TryGetValue(px, out var f)) return f;
        f = new Font(FontFamily, px, FontStyle.Bold, GraphicsUnit.Pixel);
        Fonts[px] = f;
        return f;
    }

    static readonly StringFormat Typographic = MakeFormat();

    static StringFormat MakeFormat()
    {
        var f = (StringFormat)StringFormat.GenericTypographic.Clone();
        f.FormatFlags |= StringFormatFlags.MeasureTrailingSpaces | StringFormatFlags.NoWrap;
        return f;
    }

    public static float Measure(Graphics g, string s, float px) =>
        s.Length == 0 ? 0 : g.MeasureString(s, Font(px), PointF.Empty, Typographic).Width;

    /// Draw `word` with its anchor letter centred on `anchorX`, shrinking the
    /// size only as far as needed to fit the room either side. Returns the
    /// size used. `top` is the top of the text box.
    public static float Draw(Graphics g, string word, float anchorX, float top,
                             float baseSize, float minSize, float leftRoom, float rightRoom,
                             bool dimmed = false)
    {
        if (word.Length == 0) return baseSize;
        // Index by text elements so a surrogate pair or accent stays whole.
        var elements = System.Globalization.StringInfo.GetTextElementEnumerator(word);
        var parts = new List<string>();
        while (elements.MoveNext()) parts.Add((string)elements.Current);
        int orp = Math.Min(OrpIndex(parts.Count), parts.Count);
        var pre = string.Concat(parts.Take(orp - 1));
        var anchor = parts[orp - 1];
        var post = string.Concat(parts.Skip(orp));

        float size = baseSize;
        float leftNeed = Measure(g, pre, size) + Measure(g, anchor, size) / 2;
        float rightNeed = Measure(g, word, size) - leftNeed;
        float scale = 1;
        if (leftNeed > 0) scale = Math.Min(scale, leftRoom / leftNeed);
        if (rightNeed > 0) scale = Math.Min(scale, rightRoom / rightNeed);
        if (scale < 1) size = Math.Max(minSize, (float)Math.Floor(size * scale));

        var font = Font(size);
        float preW = Measure(g, pre, size), anchorW = Measure(g, anchor, size);
        float x = anchorX - preW - anchorW / 2;
        int alpha = dimmed ? 128 : 247;
        using var baseBrush = new SolidBrush(Color.FromArgb(alpha, 255, 255, 255));
        using var orpBrush = new SolidBrush(Color.FromArgb(dimmed ? 128 : 255, OrpColor));
        g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAlias;
        g.DrawString(pre, font, baseBrush, x, top, Typographic);
        g.DrawString(anchor, font, orpBrush, x + preW, top, Typographic);
        g.DrawString(post, font, baseBrush, x + preW + anchorW, top, Typographic);
        return size;
    }

    public static string[] Words(string text) =>
        text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
}
