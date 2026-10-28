using System.Runtime.InteropServices;

namespace DoubaoVoiceBridge.Windows.Native;

// Opt-in Windows-only harness. It can inject only into its own focused TextBox, never a remote window.
public static class NativeSmoke
{
    public static IReadOnlyList<string> Run(TextBox textBox)
    {
        if (Thread.CurrentThread.GetApartmentState() != ApartmentState.STA) throw new InvalidOperationException("smoke_requires_sta");
        var form = textBox.FindForm() ?? throw new InvalidOperationException("smoke_requires_form");
        form.Activate();
        textBox.Focus();
        Application.DoEvents();
        RequireOwnedForeground(form, textBox);
        var inputSize = Marshal.SizeOf<NativeMethods.Input>();
        if (inputSize != (IntPtr.Size == 8 ? 40 : 28)) throw new InvalidOperationException("smoke_input_layout_invalid");
        var result = new List<string> { $"input-layout:{inputSize}" };
        using var clipboard = new ClipboardStore();
        const string sample = "豆包桥接 Smoke 中文 🙂\r\nline2";
        var lease = clipboard.Stage(sample, captureSnapshot: true);
        try
        {
            if (!clipboard.Contains(sample)) throw new InvalidOperationException("smoke_clipboard_roundtrip_failed");
            result.Add("clipboard-unicode-roundtrip");
            textBox.Clear();
            RequireOwnedForeground(form, textBox);
            if (new[] { 0x10, 0x11, 0x12, 0x5B, 0x5C }.Any(key => (NativeMethods.GetAsyncKeyState(key) & 0x8000) != 0))
                throw new InvalidOperationException("smoke_modifiers_down");
            var inputs = new[] { Key(0xA2, false), Key(0x56, false), Key(0x56, true), Key(0xA2, true) };
            var sent = NativeMethods.SendInput(4, inputs, inputSize);
            if (sent != 4)
            {
                var releases = new[] { Key(0x56, true), Key(0xA2, true) };
                NativeMethods.SendInput(2, releases, inputSize);
                throw new InvalidOperationException("smoke_sendinput_blocked");
            }
            var deadline = Environment.TickCount64 + 1500;
            while (textBox.Text != sample && Environment.TickCount64 < deadline)
            {
                Application.DoEvents();
                Thread.Sleep(10);
            }
            if (textBox.Text != sample) throw new InvalidOperationException("smoke_paste_failed");
            result.Add("owned-window-ctrl-v");
        }
        finally
        {
            if (!clipboard.Restore(lease)) throw new InvalidOperationException("smoke_clipboard_ownership_changed_restore_skipped");
        }
        result.Add("clipboard-owned-restore");
        return result;
    }

    private static void RequireOwnedForeground(Form form, TextBox textBox)
    {
        var foreground = NativeMethods.GetForegroundWindow();
        NativeMethods.GetWindowThreadProcessId(foreground, out var pid);
        if (foreground != form.Handle || pid != Environment.ProcessId || !textBox.Focused)
            throw new InvalidOperationException("smoke_foreground_not_owned");
    }

    private static NativeMethods.Input Key(ushort key, bool up) => new()
    {
        Type = 1,
        Data = new NativeMethods.InputUnion { Keyboard = new NativeMethods.KeyboardInput
        {
            VirtualKey = key, Flags = up ? NativeMethods.KeyUp : 0, ExtraInfo = NativeMethods.InjectionMarker
        } }
    };
}
