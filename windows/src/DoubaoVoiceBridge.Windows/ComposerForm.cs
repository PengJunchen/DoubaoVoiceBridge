using System.Runtime.InteropServices;
using DoubaoVoiceBridge.Core;
using DoubaoVoiceBridge.Windows.Native;

namespace DoubaoVoiceBridge.Windows;

internal sealed class ComposerForm : Form, IComposerHost
{
    private readonly ImeTextBox editor = new();
    private readonly Label status = new() { AutoSize = false, Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleLeft };
    private readonly Button finish = new() { Text = "完成识别", AutoSize = true };
    private readonly Button deliver = new() { Text = "粘贴到原 UU 会话", AutoSize = true };
    private readonly Button cancel = new() { Text = "取消", AutoSize = true };
    private bool showWithoutActivation;
    public event Action? FinishRequested;
    public event Action? DeliveryRequested;
    public event Action? CancelRequested;
    public event Action? InputStateChanged;
    protected override bool ShowWithoutActivation => showWithoutActivation;

    public ComposerForm()
    {
        Text = "远控听写 · 本机豆包输入框";
        Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath);
        Size = new(660, 360);
        MinimumSize = new(500, 300);
        StartPosition = FormStartPosition.CenterScreen;
        BackColor = Color.FromArgb(244, 245, 247);
        Font = new("Microsoft YaHei UI", 10);
        var layout = new TableLayoutPanel { Dock = DockStyle.Fill, Padding = new(18), RowCount = 4, ColumnCount = 1 };
        layout.RowStyles.Add(new(SizeType.Absolute, 40));
        layout.RowStyles.Add(new(SizeType.Percent, 100));
        layout.RowStyles.Add(new(SizeType.Absolute, 55));
        layout.RowStyles.Add(new(SizeType.Absolute, 42));
        layout.Controls.Add(new Label { Text = "文字在本机识别；粘贴后请自行发送远端消息", Dock = DockStyle.Fill, AutoSize = true }, 0, 0);
        editor.Multiline = true;
        editor.AcceptsReturn = true;
        editor.ScrollBars = ScrollBars.Vertical;
        editor.Dock = DockStyle.Fill;
        editor.ImeMode = ImeMode.On;
        editor.TextChanged += (_, _) => InputStateChanged?.Invoke();
        editor.CompositionChanged += () => InputStateChanged?.Invoke();
        layout.Controls.Add(editor, 0, 1);
        layout.Controls.Add(status, 0, 2);
        var buttons = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.LeftToRight };
        buttons.Controls.AddRange([finish, deliver, cancel]);
        layout.Controls.Add(buttons, 0, 3);
        Controls.Add(layout);
        finish.Click += (_, _) => { editor.Focus(); FinishRequested?.Invoke(); };
        deliver.Click += (_, _) => { editor.Focus(); DeliveryRequested?.Invoke(); };
        cancel.Click += (_, _) => CancelRequested?.Invoke();
        FormClosing += (_, e) => { if (e.CloseReason == CloseReason.UserClosing) { e.Cancel = true; CancelRequested?.Invoke(); } };
        KeyPreview = true;
        KeyDown += (_, e) =>
        {
            if (e.KeyCode == Keys.Escape && !editor.IsComposing)
            {
                e.SuppressKeyPress = true;
                CancelRequested?.Invoke();
            }
        };
    }

    public bool IsComposerForeground => Visible && NativeBridgePlatform.IsOwnForegroundWindow(Handle) && ContainsFocus;
    public TranscriptSnapshot ReadTranscript() => new(editor.Text, editor.IsComposing, IsComposerForeground && editor.Focused);
    public Task ShowComposerAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        editor.Clear();
        editor.ResetComposition();
        editor.ReadOnly = false;
        Show();
        WindowState = FormWindowState.Normal;
        Activate();
        editor.Focus();
        return Task.CompletedTask;
    }
    public void HideComposer() => Hide();
    public void ShowPreserved(bool activate = true)
    {
        showWithoutActivation = !activate;
        Show();
        WindowState = FormWindowState.Normal;
        if (activate) { Activate(); editor.Focus(); }
        showWithoutActivation = false;
    }
    public void SetStatus(string message) => status.Text = message;
    public void SetState(BridgeState state)
    {
        var busy = state is BridgeState.Delivering;
        finish.Enabled = !busy;
        deliver.Enabled = !busy;
        editor.ReadOnly = busy;
    }

    private sealed class ImeTextBox : TextBox
    {
        public bool IsComposing { get; private set; }
        public event Action? CompositionChanged;
        public void ResetComposition() => IsComposing = false;
        protected override void WndProc(ref Message m)
        {
            if (m.Msg == 0x010D) { IsComposing = true; CompositionChanged?.Invoke(); } // WM_IME_STARTCOMPOSITION
            if (m.Msg == 0x010E) { IsComposing = false; CompositionChanged?.Invoke(); } // WM_IME_ENDCOMPOSITION
            // Keep synthesized activation keys out of editor commands/character insertion.
            // IME processing occurs upstream; native edit still receives IME result messages.
            if (m.Msg is 0x0100 or 0x0101 or 0x0102 or 0x0104 or 0x0105 or 0x0106 && NativeBridgePlatform.IsBridgeInjectedMessage)
                return;
            base.WndProc(ref m);
        }
    }
}
