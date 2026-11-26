namespace BellowFlo;

/// Appends to BellowFlo.log in the data folder. A tray app has nowhere to
/// print, and "it launched but nothing works" is otherwise unanswerable.
/// Synchronous: a line is tiny, and lines must stay in order.
static class Log
{
    static readonly object Gate = new();

    public static void Write(string message)
    {
        var line = $"{DateTime.Now:yyyy-MM-dd HH:mm:ss}  {message}{Environment.NewLine}";
        lock (Gate)
        {
            try { File.AppendAllText(Paths.AppLog, line); }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
    }
}
