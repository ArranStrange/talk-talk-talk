using NAudio.Wave;

namespace BellowFlo;

/// Captures the microphone as 16 kHz mono 16-bit PCM and writes a WAV.
/// Windows' audio engine converts from the device format, so no resampling
/// happens here.
///
/// Recording lives in the app rather than the daemon so it is this app the
/// Windows microphone privacy setting has to allow, not a Python child.
sealed class Recorder
{
    public const int SampleRate = 16000;
    WaveInEvent? wave;
    MemoryStream pcm = new();
    readonly object gate = new();
    ManualResetEventSlim? stopped;
    Exception? failure;

    public bool IsRecording => wave != null;

    public void Start()
    {
        if (wave != null) return;
        pcm = new MemoryStream();
        failure = null;
        stopped = new ManualResetEventSlim(false);
        // NAudio captures the creating thread's SynchronizationContext and
        // posts RecordingStopped to it. Created on the UI thread, Stop()'s
        // wait below would block the very thread that event is queued on and
        // always run its full timeout. Without a context it fires directly.
        var saved = SynchronizationContext.Current;
        SynchronizationContext.SetSynchronizationContext(null);
        WaveInEvent w;
        try
        {
            w = new WaveInEvent
            {
                DeviceNumber = -1,                  // WAVE_MAPPER: follows the default input device
                WaveFormat = new WaveFormat(SampleRate, 16, 1),
                BufferMilliseconds = 50,
            };
        }
        finally
        {
            SynchronizationContext.SetSynchronizationContext(saved);
        }
        w.DataAvailable += (_, e) =>
        {
            lock (gate) pcm.Write(e.Buffer, 0, e.BytesRecorded);
        };
        w.RecordingStopped += (_, e) =>
        {
            failure = e.Exception;
            stopped?.Set();
        };
        try
        {
            w.StartRecording();
        }
        catch
        {
            w.Dispose();
            throw;
        }
        wave = w;
    }

    /// True when the last recording was digital silence: what Windows
    /// delivers when the microphone privacy setting blocks desktop apps,
    /// rather than an error.
    public bool LastWasSilent { get; private set; }

    /// Stops and writes the WAV. Returns its duration in seconds, or null if
    /// nothing could be written.
    public double? Stop(string path)
    {
        var w = wave;
        if (w == null) return null;
        wave = null;
        w.StopRecording();
        // The last buffers arrive before RecordingStopped; wait for them.
        stopped?.Wait(1000);
        w.Dispose();
        if (failure != null) Log.Write($"recording ended with: {failure.Message}");
        byte[] data;
        lock (gate) data = pcm.ToArray();
        double seconds = data.Length / 2.0 / SampleRate;
        LastWasSilent = data.Length > 0 && data.All(b => b == 0);
        try
        {
            using (var writer = new WaveFileWriter(path + ".tmp", new WaveFormat(SampleRate, 16, 1)))
                writer.Write(data, 0, data.Length);
            File.Move(path + ".tmp", path, overwrite: true);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            // Antivirus or the engine can hold the file for a moment; the
            // caller treats null as "no recording" and resets the state.
            Log.Write($"could not write the recording: {e.Message}");
            return null;
        }
        return seconds;
    }
}
