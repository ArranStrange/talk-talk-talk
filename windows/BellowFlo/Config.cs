using System.Text.Json;
using System.Text.Json.Nodes;

namespace BellowFlo;

/// The engine's config.json, shared with the Python side. Kept as a raw JSON
/// object on purpose: the hooks and tldr.py write keys this app does not
/// know, and a typed round-trip would erase them on the next menu click.
sealed class Config
{
    public JsonObject Raw { get; }

    public Config()
    {
        JsonObject? parsed = null;
        try { parsed = JsonNode.Parse(Paths.Read(Paths.Config)) as JsonObject; }
        catch (JsonException) { }
        Raw = parsed ?? new JsonObject();
    }

    public string Voice => Str("voice") ?? "af_heart";
    public string Lang => Str("lang") ?? "en-us";
    public double Speed => Num("speed") ?? 1.1;
    public bool TldrOn => Bool("tldr_replies") ?? false;
    public string TldrProvider => Str("tldr_provider") ?? "claude-cli";
    public string? TldrModel => Str("tldr_model");
    public int TldrSentences => (int)(Num("tldr_sentences") ?? 3);
    public int TldrMinWords => (int)(Num("tldr_min_words") ?? 70);
    public string? WorkspaceId => Str("anthropic_workspace_id");

    public string? Str(string key) =>
        Raw[key] is JsonValue v && v.TryGetValue<string>(out var s) ? s : null;

    public double? Num(string key)
    {
        if (Raw[key] is not JsonValue v) return null;
        if (v.TryGetValue<double>(out var d)) return d;
        if (v.TryGetValue<int>(out var i)) return i;
        if (v.TryGetValue<long>(out var l)) return l;
        return null;
    }

    public bool? Bool(string key) =>
        Raw[key] is JsonValue v && v.TryGetValue<bool>(out var b) ? b : null;

    static readonly JsonSerializerOptions Pretty = new() { WriteIndented = false };

    /// Read-modify-write, so two quick menu clicks cannot lose each other's
    /// key. Keys are sorted to match what the macOS app writes.
    public static void Update(Action<JsonObject> change)
    {
        var raw = new Config().Raw;
        change(raw);
        var sorted = new JsonObject();
        foreach (var key in raw.Select(kv => kv.Key).OrderBy(k => k, StringComparer.Ordinal).ToList())
        {
            var value = raw[key];
            raw.Remove(key);
            sorted[key] = value;
        }
        Paths.Write(sorted.ToJsonString(Pretty), Paths.Config);
    }

    /// Null removes the key.
    public static void Set(string key, JsonNode? value) =>
        Update(o => { if (value is null) o.Remove(key); else o[key] = value; });
}
