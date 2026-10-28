using DoubaoVoiceBridge.Windows.Native;

internal static class Program
{
    [STAThread]
    private static int Main()
    {
        ApplicationConfiguration.Initialize();
        using var form = new Form { Text = "DoubaoVoiceBridge owned-window smoke", Width = 500, Height = 240, StartPosition = FormStartPosition.CenterScreen };
        using var text = new TextBox { Multiline = true, Dock = DockStyle.Fill };
        form.Controls.Add(text);
        var result = 1;
        form.Shown += (_, _) => form.BeginInvoke(() =>
        {
            try
            {
                foreach (var passed in NativeSmoke.Run(text)) Console.WriteLine($"PASS {passed}");
                result = 0;
            }
            catch (Exception ex)
            {
                // Stable smoke error codes contain no user text, paths or clipboard payload.
                Console.Error.WriteLine($"FAIL {ex.GetType().Name}");
                if (ex is InvalidOperationException && ex.Message.StartsWith("smoke_", StringComparison.Ordinal))
                    Console.Error.WriteLine(ex.Message);
                if (ex is NativeBridgeException native) Console.Error.WriteLine($"{native.Code} native={native.NativeError}");
            }
            finally { form.Close(); }
        });
        Application.Run(form);
        return result;
    }
}
