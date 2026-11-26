using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32;
using static BellowFlo.Native;

namespace BellowFlo;

/// A one-field prompt. `secret` hides what is typed.
sealed class Prompt : Form
{
    readonly TextBox box;

    Prompt(string title, string message, string value, bool secret)
    {
        Text = title;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = MinimizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;
        TopMost = true;
        AutoScaleMode = AutoScaleMode.Dpi;
        AutoScaleDimensions = new SizeF(96, 96);
        Font = new Font("Segoe UI", 9.5f);
        ClientSize = new Size(420, 150);

        var label = new Label { Text = message, Left = 14, Top = 12, Width = 392, Height = 52 };
        box = new TextBox { Left = 14, Top = 68, Width = 392, Text = value, UseSystemPasswordChar = secret };
        var ok = new Button { Text = "Save", DialogResult = DialogResult.OK, Left = 238, Top = 108, Width = 80 };
        var cancel = new Button { Text = "Cancel", DialogResult = DialogResult.Cancel, Left = 326, Top = 108, Width = 80 };
        Controls.AddRange(new Control[] { label, box, ok, cancel });
        AcceptButton = ok;
        CancelButton = cancel;
    }

    public static string? Ask(string title, string message, string value = "", bool secret = false)
    {
        using var p = new Prompt(title, message, value, secret);
        p.Shown += (_, _) => { p.Activate(); p.box.Focus(); };
        return p.ShowDialog() == DialogResult.OK ? p.box.Text : null;
    }
}

/// API keys in Credential Manager, under the same names bf_secrets.py reads:
/// target "bellowflo-<provider>", user "bellow-flo", the key as UTF-16LE.
static class Credentials
{
    public static string Target(string provider) => $"bellowflo-{provider}";

    public static void Store(string provider, string key)
    {
        var blob = Encoding.Unicode.GetBytes(key);           // UTF-16LE, no BOM
        var mem = Marshal.AllocHGlobal(blob.Length);
        try
        {
            Marshal.Copy(blob, 0, mem, blob.Length);
            var cred = new CREDENTIAL
            {
                Type = CRED_TYPE_GENERIC,
                TargetName = Target(provider),
                CredentialBlobSize = (uint)blob.Length,
                CredentialBlob = mem,
                Persist = CRED_PERSIST_LOCAL_MACHINE,
                UserName = "bellow-flo",
            };
            if (!CredWrite(ref cred, 0))
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        }
        finally
        {
            // Overwrite the key's bytes before handing the memory back.
            Marshal.Copy(new byte[blob.Length], 0, mem, blob.Length);
            Marshal.FreeHGlobal(mem);
            Array.Clear(blob);
        }
    }

    public static int StoredLength(string provider)
    {
        if (!CredRead(Target(provider), CRED_TYPE_GENERIC, 0, out var p)) return 0;
        try
        {
            var c = Marshal.PtrToStructure<CREDENTIAL>(p);
            return (int)c.CredentialBlobSize / 2;
        }
        finally { CredFree(p); }
    }

    /// Ask for a key in a hidden field and store it. Reports the shape of
    /// what landed without ever showing it, as bellowflo-set-key does.
    public static void AskAndStore(string provider, string label, string prefix)
    {
        var key = Prompt.Ask($"{label} API key",
            $"Paste your {label} API key. It is stored in Windows Credential Manager " +
            "and never written to a file.", secret: true);
        if (key == null) return;
        key = key.Trim();
        if (key.Length == 0) { Hud.Show("Nothing was stored"); return; }
        try { Store(provider, key); }
        catch (Exception e)
        {
            Hud.Show($"Not stored: {e.Message}", 4);
            return;
        }
        var note = $"Saved ({StoredLength(provider)} characters).";
        if (!key.StartsWith(prefix)) note += $"\nIt does not start with '{prefix}' — is this the right key?";
        if (key.Any(char.IsWhiteSpace)) note += "\nIt contains a space or line break: paste only the key.";
        Hud.Show(note, 4);
    }
}

/// Start at login, through the per-user Run key. No admin rights needed.
static class LoginItem
{
    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    const string Name = "Bellow Flo";

    static string Command => $"\"{Environment.ProcessPath}\"";

    public static bool Enabled
    {
        get
        {
            using var k = Registry.CurrentUser.OpenSubKey(RunKey);
            return k?.GetValue(Name) is string v && v == Command;
        }
    }

    /// A message to show on failure, else null.
    public static string? Set(bool on)
    {
        try
        {
            using var k = Registry.CurrentUser.CreateSubKey(RunKey);
            if (on) k.SetValue(Name, Command); else k.DeleteValue(Name, false);
            return null;
        }
        catch (Exception e)
        {
            return $"Could not {(on ? "enable" : "disable")} start at login: {e.Message}";
        }
    }
}
