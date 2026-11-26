using System.Text.Json;
using System.Text.Json.Nodes;

namespace BellowFlo;

/// UI preferences that are the app's alone; the engine never reads them.
/// The macOS app keeps these in its defaults; here they are a small JSON
/// file in the data folder.
static class Prefs
{
    static readonly object Gate = new();
    static JsonObject? cache;

    static JsonObject Load()
    {
        if (cache != null) return cache;
        try { cache = JsonNode.Parse(Paths.Read(Paths.AppPrefs)) as JsonObject; }
        catch (JsonException) { }
        return cache ??= new JsonObject();
    }

    static void Save() => Paths.Write(Load().ToJsonString(), Paths.AppPrefs);

    static T Get<T>(string key, T fallback)
    {
        lock (Gate)
        {
            return Load()[key] is JsonValue v && v.TryGetValue<T>(out var x) ? x : fallback;
        }
    }

    static void Put(string key, JsonNode? value)
    {
        lock (Gate)
        {
            var o = Load();
            if (value is null) o.Remove(key); else o[key] = value;
            Save();
        }
    }

    public static bool AutoRead
    {
        get => Get("autoRead", false);
        set => Put("autoRead", value);
    }

    public static bool ReadAlong
    {
        get => Get("readAlong", false);
        set => Put("readAlong", value);
    }

    public static int ReaderWpm
    {
        get => Get("readerWpm", 350);
        set => Put("readerWpm", value);
    }

    public static bool StartedBefore
    {
        get => Get("startedBefore", false);
        set => Put("startedBefore", value);
    }

    // -- recent dictations ----------------------------------------------------

    public sealed record Dictation(string Text, string? Raw, DateTime Date);
    public const int RecentLimit = 10;

    public static List<Dictation> RecentDictations
    {
        get
        {
            lock (Gate)
            {
                try
                {
                    return Load()["recentDictations"]?.Deserialize<List<Dictation>>() ?? new();
                }
                catch (JsonException) { return new(); }
            }
        }
        set => Put("recentDictations",
                   JsonSerializer.SerializeToNode(value.Take(RecentLimit).ToList()));
    }

    /// Most recent first. Dictating the same thing again moves it to the top.
    public static void Remember(string text, string? raw)
    {
        var t = text.Trim();
        if (t.Length == 0) return;
        var list = RecentDictations.Where(d => d.Text != t).ToList();
        list.Insert(0, new Dictation(t, raw == t ? null : raw, DateTime.Now));
        RecentDictations = list;
    }

    public static void ClearRecentDictations() => Put("recentDictations", null);

    /// The pill's top-right corner in screen pixels. The top-right rather
    /// than the origin because the pill keeps its right edge fixed while its
    /// width changes with the label.
    public static Point? PillAnchor
    {
        get
        {
            lock (Gate)
            {
                if (Load()["pillAnchor"] is JsonArray a && a.Count == 2
                    && a[0] is JsonValue x && a[1] is JsonValue y
                    && x.TryGetValue<int>(out var xi) && y.TryGetValue<int>(out var yi))
                    return new Point(xi, yi);
                return null;
            }
        }
        set => Put("pillAnchor", value is Point p ? new JsonArray(p.X, p.Y) : null);
    }
}
