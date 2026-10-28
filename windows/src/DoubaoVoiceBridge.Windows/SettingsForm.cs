using DoubaoVoiceBridge.Core;

namespace DoubaoVoiceBridge.Windows;

internal sealed class SettingsForm : Form
{
    private BridgeSettings baseline;
    private readonly ComboBox trigger = Choice();
    private readonly ComboBox voiceKey = Choice();
    private readonly ComboBox voiceMode = Choice();
    private readonly ComboBox pasteChord = Choice();
    private readonly CheckedListBox modifiers = new() { Width = 420, Height = 64, CheckOnClick = true, MultiColumn = true, ColumnWidth = 130 };
    private readonly NumericUpDown sync = Number(450, 10000);
    private readonly NumericUpDown restoreDelay = Number(2000, 30000);
    private readonly NumericUpDown settle = Number(350, 3000);
    private readonly CheckBox autoPaste = new() { Text = "识别完成后自动粘贴（实机验证后再开启）", AutoSize = true };
    private readonly CheckBox restore = new() { Text = "粘贴后恢复原剪贴板（仅支持可安全备份的格式）", AutoSize = true };
    private readonly CheckBox test = new() { Text = "F8 / 远控键仅打开测试文字框，不启动语音", AutoSize = true };
    private readonly Label enrollment = new() { AutoSize = true, MaximumSize = new(650, 0) };
    private readonly Label status = new() { AutoSize = true, MaximumSize = new(650, 0), ForeColor = Color.FromArgb(55, 80, 110) };
    public event Action<BridgeSettings>? SaveRequested;
    public event Action? EnrollRequested;
    public event Action? ExportRequested;
    public event Action? QuitRequested;
    public bool TestMode => test.Checked;
    [System.ComponentModel.DesignerSerializationVisibility(System.ComponentModel.DesignerSerializationVisibility.Hidden)]
    public bool AllowQuit { get; set; }
    private static ComboBox Choice() => new() { DropDownStyle = ComboBoxStyle.DropDownList, Width = 420 };
    private static NumericUpDown Number(int min, int max) => new() { Minimum = min, Maximum = max, Increment = 100, Width = 150 };
    private sealed record KeyChoice(string Name, int Code) { public override string ToString() => Name; }

    public SettingsForm(BridgeSettings settings)
    {
        baseline = settings;
        Text = "远控听写 · Windows 设置";
        Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath);
        Font = new("Microsoft YaHei UI", 10);
        Size = new(780, 880);
        MinimumSize = new(700, 600);
        StartPosition = FormStartPosition.CenterScreen;
        BackColor = Color.FromArgb(244, 245, 247);
        var flow = new FlowLayoutPanel { Dock = DockStyle.Fill, AutoScroll = true, FlowDirection = FlowDirection.TopDown, WrapContents = false, Padding = new(24) };
        void Copy(string text) => flow.Controls.Add(new Label { Text = text, AutoSize = true, MaximumSize = new(660, 0), Margin = new(0, 6, 0, 10) });
        void Field(string label, Control control)
        {
            flow.Controls.Add(new Label { Text = label, AutoSize = true, Margin = new(0, 8, 0, 4) });
            control.Margin = new(0, 0, 0, 5);
            flow.Controls.Add(control);
        }
        Copy("先绑定 UU 会话窗口，再在远端点选输入框。按远控键后，本机听写框会接收豆包文字。");
        var bind = new Button { Text = "绑定 UU 会话窗口（点击后 5 秒内切换到 UU）", AutoSize = true };
        bind.Click += (_, _) => EnrollRequested?.Invoke();
        flow.Controls.Add(bind);
        flow.Controls.Add(enrollment);
        for (int i = 1; i <= 24; i++) trigger.Items.Add(new KeyChoice($"F{i}", 0x6F + i));
        Field("远控触发键（仅绑定程序前台时独占；原功能键不会传到远端）", trigger);
        voiceMode.Items.AddRange(["手动启动 / 停止豆包（首次验证推荐）", "模拟按住：按下启动，松开停止", "模拟切换：同一组合键分别启动和停止"]);
        Field("豆包语音方式", voiceMode);
        voiceKey.Items.AddRange([new KeyChoice("空格", 0x20), new KeyChoice("左 Alt（单键）", 0xA4), new KeyChoice("右 Alt（单键）", 0xA5), new KeyChoice("左 Ctrl（单键）", 0xA2), new KeyChoice("右 Ctrl（单键）", 0xA3)]);
        for (int i = 1; i <= 24; i++) voiceKey.Items.Add(new KeyChoice($"F{i}", 0x6F + i));
        for (int i = 'A'; i <= 'Z'; i++) voiceKey.Items.Add(new KeyChoice(((char)i).ToString(), i));
        Field("豆包主键（必须与豆包设置一致）", voiceKey);
        modifiers.Items.AddRange([new KeyChoice("左 Alt", 0xA4), new KeyChoice("右 Alt", 0xA5), new KeyChoice("左 Ctrl", 0xA2), new KeyChoice("右 Ctrl", 0xA3), new KeyChoice("左 Shift", 0xA0), new KeyChoice("右 Shift", 0xA1)]);
        Field("豆包组合修饰键（单键启动时全部取消勾选）", modifiers);
        pasteChord.Items.AddRange(["Ctrl + V（Windows；Mac 优先测试 UU 映射）", "Win + V（仅当 UU 将 Win 映射到 Mac Command）", "Alt + V（仅当 UU 将 Alt 映射到 Mac Command）"]);
        Field("远端粘贴键", pasteChord);
        Field("等待 UU 剪贴板同步（毫秒）", sync);
        Field("最终文字稳定等待（毫秒）", settle);
        flow.Controls.Add(autoPaste);
        flow.Controls.Add(restore);
        Field("粘贴后恢复等待（毫秒）", restoreDelay);
        flow.Controls.Add(test);
        Copy("手动方式：在听写框中使用豆包快捷键，结束豆包录音后点「完成识别」，核对文字再点「粘贴」。模拟方式仍需实机验证；自动粘贴只依据文字稳定时间，无法确认豆包服务或远端已完成。");
        var buttons = new FlowLayoutPanel { AutoSize = true, WrapContents = true, MaximumSize = new(660, 0) };
        foreach (var (label, action) in new (string, Action)[] {
            ("保存设置", Save), ("导出诊断 ZIP", () => ExportRequested?.Invoke()), ("打开数据目录", OpenData), ("退出应用", () => QuitRequested?.Invoke()) })
        {
            var button = new Button { Text = label, AutoSize = true };
            button.Click += (_, _) => action();
            buttons.Controls.Add(button);
        }
        flow.Controls.Add(buttons);
        flow.Controls.Add(status);
        Controls.Add(flow);
        LoadValues(settings);
        FormClosing += (_, e) => { if (!AllowQuit && e.CloseReason == CloseReason.UserClosing) { e.Cancel = true; Hide(); } };
    }

    private void LoadValues(BridgeSettings s)
    {
        trigger.SelectedIndex = s.TriggerKey - 0x70;
        voiceMode.SelectedIndex = s.VoiceMode switch { VoiceMode.Manual => 0, VoiceMode.Hold => 1, _ => 2 };
        voiceKey.SelectedItem = voiceKey.Items.Cast<KeyChoice>().FirstOrDefault(k => k.Code == s.VoiceKey);
        if (voiceKey.SelectedItem is null) { voiceKey.Items.Add(new KeyChoice($"VK 0x{s.VoiceKey:X2}", s.VoiceKey)); voiceKey.SelectedIndex = voiceKey.Items.Count - 1; }
        for (int i = 0; i < modifiers.Items.Count; i++) modifiers.SetItemChecked(i, s.VoiceModifiers.Contains(((KeyChoice)modifiers.Items[i]).Code));
        pasteChord.SelectedIndex = (int)s.PasteChord;
        sync.Value = s.SyncDelayMs;
        settle.Value = s.SettleMs;
        restoreDelay.Value = s.RestoreDelayMs;
        autoPaste.Checked = s.AutoPaste;
        restore.Checked = s.RestoreClipboard;
        SetEnrolled(s);
    }
    public void SetEnrolled(BridgeSettings settings)
    {
        baseline = settings;
        enrollment.Text = string.IsNullOrWhiteSpace(settings.ApprovedExecutablePath) ? "尚未绑定：不会向任何窗口投递。" : "已绑定：" + Path.GetFileName(settings.ApprovedExecutablePath) + "（同一程序的当前会话）";
    }
    public void SetStatus(string text) => status.Text = text;
    private void Save()
    {
        if (trigger.SelectedItem is not KeyChoice t || voiceKey.SelectedItem is not KeyChoice v) return;
        var value = baseline with
        {
            TriggerKey = t.Code, VoiceKey = v.Code,
            VoiceMode = voiceMode.SelectedIndex switch { 0 => VoiceMode.Manual, 1 => VoiceMode.Hold, _ => VoiceMode.Toggle },
            VoiceModifiers = modifiers.CheckedItems.Cast<KeyChoice>().Select(k => k.Code).ToArray(),
            PasteChord = (PasteChord)pasteChord.SelectedIndex, SyncDelayMs = (int)sync.Value, SettleMs = (int)settle.Value,
            RestoreDelayMs = (int)restoreDelay.Value, AutoPaste = autoPaste.Checked, RestoreClipboard = restore.Checked
        };
        var errors = SettingsValidator.Validate(value);
        if (errors.Count != 0) { SetStatus(string.Join("；", errors)); return; }
        SaveRequested?.Invoke(value);
    }
    private static void OpenData()
    {
        Directory.CreateDirectory(AppData.Root);
        System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(AppData.Root) { UseShellExecute = true });
    }
}
