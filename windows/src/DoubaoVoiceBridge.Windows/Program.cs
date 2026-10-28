using DoubaoVoiceBridge.Core;
using DoubaoVoiceBridge.Windows.Native;

namespace DoubaoVoiceBridge.Windows;

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        using var mutex = new Mutex(true, "Local\\DoubaoVoiceBridge.Windows", out var created);
        if (!created) { MessageBox.Show("远控听写已经运行，请从系统托盘打开设置。", "远控听写"); return; }
        ApplicationConfiguration.Initialize();
        using var log = new DiagnosticLog();
        BridgeApplication? app = null;
        Application.SetUnhandledExceptionMode(UnhandledExceptionMode.CatchException);
        Application.ThreadException += (_, e) =>
        {
            log.Write("app.ui_exception", fields: new { errorType = e.Exception.GetType().Name });
            app?.EmergencyStop();
            MessageBox.Show("应用遇到错误，已暂停当前操作。请导出诊断日志并检查远端是否已粘贴。", "远控听写");
        };
        AppDomain.CurrentDomain.UnhandledException += (_, e) => log.Write("app.unhandled_exception", fields: new { errorType = e.ExceptionObject.GetType().Name });
        try
        {
            using (app = new BridgeApplication(log)) Application.Run(app);
        }
        catch (Exception ex)
        {
            log.Write("app.start_failed", fields: new { errorType = ex.GetType().Name });
            MessageBox.Show("无法启动远控听写，请检查数据目录中的诊断日志。\n" + AppData.Root, "远控听写");
        }
    }
}

internal sealed class BridgeApplication : ApplicationContext
{
    private BridgeSettings settings;
    private readonly DiagnosticLog log;
    private readonly SettingsForm settingsForm;
    private readonly ComposerForm composer;
    private readonly NativeBridgePlatform platform;
    private BridgeCoordinator coordinator;
    private readonly GlobalTrigger trigger;
    private readonly NotifyIcon tray;
    private readonly System.Windows.Forms.Timer health;
    private bool quitting;
    private bool enrolling;
    private Task begin = Task.CompletedTask;
    private BridgeCoordinator? heldCoordinator;
    private string? heldSessionId;
    private bool finishOnRelease;

    public BridgeApplication(DiagnosticLog log)
    {
        this.log = log;
        settings = AppData.Load(log);
        composer = new();
        settingsForm = new(settings);
        // Establish UI handles before hook callbacks schedule work.
        _ = settingsForm.Handle;
        _ = composer.Handle;
        platform = new(() => settings, log, composer);
        coordinator = CreateCoordinator();
        platform.SessionIdProvider = () => coordinator.SessionId;
        trigger = new(() => settings,
            () => !enrolling && coordinator.State == BridgeState.Idle && !settingsForm.ContainsFocus,
            () => platform.IsApprovedForegroundFast,
            () => Queue(OnPressed), () => Queue(OnReleased), log);
        composer.FinishRequested += () => Run(() => coordinator.FinishAsync());
        composer.DeliveryRequested += () => Run(() => coordinator.DeliverAsync());
        composer.CancelRequested += () => Run(Cancel);
        composer.InputStateChanged += () =>
        {
            if (coordinator.State == BridgeState.Idle) return;
            var snapshot = composer.ReadTranscript();
            var bucket = snapshot.Text.Length switch { 0 => "empty", <= 4 => "1-4", <= 16 => "5-16", <= 64 => "17-64", _ => "65+" };
            log.Write("composer.input_state", coordinator.SessionId, new { lengthBucket = bucket, composing = snapshot.IsComposing, focused = snapshot.IsFocused });
        };
        settingsForm.SaveRequested += Save;
        settingsForm.EnrollRequested += () => Run(Enroll);
        settingsForm.ExportRequested += Export;
        settingsForm.QuitRequested += () => Run(Quit);
        var menu = new ContextMenuStrip();
        menu.Items.Add("打开设置", null, (_, _) => ShowSettings());
        menu.Items.Add("返回当前听写框", null, (_, _) => { if (coordinator.State != BridgeState.Idle) composer.ShowPreserved(); });
        menu.Items.Add("取消当前会话", null, (_, _) => Run(Cancel));
        menu.Items.Add("导出诊断 ZIP", null, (_, _) => Export());
        menu.Items.Add("退出", null, (_, _) => Run(Quit));
        tray = new() { Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath) ?? SystemIcons.Application, Text = "远控听写 · Windows", Visible = true, ContextMenuStrip = menu };
        tray.DoubleClick += (_, _) => ShowSettings();
        health = new() { Interval = 500 };
        health.Tick += (_, _) => Run(() => coordinator.CheckHealthAsync());
        health.Start();
        settingsForm.Show();
        log.Write("settings.loaded", fields: AppData.SafeSettings(settings));
        SetStatus(AppData.LoadWarning ?? (trigger.Installed ? "准备就绪。首次使用请绑定 UU，并用测试模式验证粘贴。" : "键盘监听未启动，请导出日志；本次无法使用远控触发键。"));
    }

    private BridgeCoordinator CreateCoordinator()
    {
        var value = new BridgeCoordinator(settings, platform, log);
        value.Status += SetStatus;
        value.StateChanged += state =>
        {
            composer.SetState(state);
            if (state == BridgeState.Failed && !quitting) composer.ShowPreserved(activate: composer.IsComposerForeground);
        };
        return value;
    }
    private void Queue(Func<Task> work)
    {
        if (!quitting && !settingsForm.IsDisposed) settingsForm.BeginInvoke(() => Run(work));
    }
    private async void Run(Func<Task> work)
    {
        try { await work(); }
        catch (Exception ex)
        {
            log.Write("app.action_failed", coordinator.SessionId, new { errorType = ex.GetType().Name, code = (ex as IBridgeFailure)?.Code, nativeError = (ex as IBridgeFailure)?.NativeError });
            SetStatus("操作未完成，请导出诊断日志；当前文字仍可检查。");
        }
    }
    private async Task OnPressed()
    {
        if (quitting || enrolling || coordinator.State != BridgeState.Idle) return;
        heldCoordinator = coordinator;
        var pasteTest = settingsForm.TestMode;
        finishOnRelease = !pasteTest && settings.VoiceMode != VoiceMode.Manual;
        begin = heldCoordinator.BeginAsync(pasteTest);
        heldSessionId = heldCoordinator.SessionId;
        await begin;
    }
    private async Task OnReleased()
    {
        var active = heldCoordinator;
        var sessionId = heldSessionId;
        var shouldFinish = finishOnRelease;
        var pending = begin;
        heldCoordinator = null;
        heldSessionId = null;
        await pending;
        if (shouldFinish && active is not null && active.SessionId == sessionId && active.State == BridgeState.Listening)
            await active.FinishAsync();
    }
    private Task Cancel() => coordinator.CancelAsync();
    public void EmergencyStop() => Run(Cancel);
    private void ShowSettings()
    {
        settingsForm.Show(); settingsForm.WindowState = FormWindowState.Normal; settingsForm.Activate();
    }
    private void SetStatus(string message)
    {
        settingsForm.SetStatus(message);
        composer.SetStatus(message);
    }
    private void Save(BridgeSettings value)
    {
        if (coordinator.State != BridgeState.Idle || enrolling) { SetStatus("请先取消当前听写或等待绑定结束，再保存设置。"); return; }
        try
        {
            AppData.Save(value);
            settings = value;
            coordinator = CreateCoordinator();
            settingsForm.SetEnrolled(value);
            log.Write("settings.saved", fields: AppData.SafeSettings(value));
            SetStatus("设置已保存。请在 UU 会话内使用已选远控键。");
        }
        catch (Exception ex) when (ex is IOException or InvalidDataException or UnauthorizedAccessException or ArgumentException)
        {
            log.Write("settings.save_failed", fields: new { errorType = ex.GetType().Name });
            SetStatus("设置保存失败，请检查数据目录访问权限。");
        }
    }
    private async Task Enroll()
    {
        if (enrolling || coordinator.State != BridgeState.Idle) { SetStatus("请先取消当前听写，再绑定 UU。"); return; }
        enrolling = true;
        try
        {
            for (int remaining = 5; remaining > 0; remaining--)
            {
                SetStatus($"请在 {remaining} 秒内切换到 UU 远控会话窗口（不要选择设备列表或其他应用）…");
                await Task.Delay(1000);
                if (quitting) return;
            }
            var target = NativeBridgePlatform.InspectForeground();
            if (target is null || target.ProcessId == Environment.ProcessId)
            {
                SetStatus("未选中外部窗口，绑定未改变。请重试并切换到 UU 会话。"); return;
            }
            // Enrollment is explicit; never guess filenames across UU versions. User verifies the chosen application.
            var executable = Path.GetFileName(target.ExecutablePath);
            var result = MessageBox.Show(settingsForm,
                $"检测到程序：{executable}\n\n请确认刚才选中的是 UU 的远控会话窗口。绑定后，远控键会在该程序前台时生效。",
                "确认绑定 UU", MessageBoxButtons.OKCancel, MessageBoxIcon.Information);
            if (result != DialogResult.OK) { SetStatus("已取消绑定。"); return; }
            var value = settings with { ApprovedExecutablePath = target.ExecutablePath };
            AppData.Save(value);
            settings = value;
            coordinator = CreateCoordinator();
            settingsForm.SetEnrolled(value);
            log.Write("target.enrolled", fields: new { target.ProcessId });
            SetStatus("绑定完成。请回到 UU，点选远端输入框后按远控键测试。");
        }
        finally { enrolling = false; }
    }
    private void Export()
    {
        using var dialog = new SaveFileDialog { Title = "导出脱敏诊断", Filter = "诊断 ZIP|*.zip", FileName = $"DoubaoVoiceBridge-diagnostics-{DateTime.Now:yyyyMMdd-HHmmss}.zip", OverwritePrompt = true };
        if (dialog.ShowDialog(settingsForm) != DialogResult.OK) return;
        // Create a fresh temporary archive before replacing an existing export.
        var temporary = dialog.FileName + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            log.Write("diagnostics.export", coordinator.SessionId, new { hookInstalled = trigger.Installed, keyHeld = trigger.Held, callbackFailures = trigger.CallbackFailures });
            log.Export(temporary, settings);
            File.Move(temporary, dialog.FileName, true);
            SetStatus("诊断已导出，不含听写正文。请附故障时间、两端系统及豆包 / UU 版本。");
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            log.Write("diagnostics.export_failed", fields: new { errorType = ex.GetType().Name });
            SetStatus("诊断导出失败，请更换保存位置。");
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
    private async Task Quit()
    {
        if (quitting) return;
        quitting = true;
        health.Stop();
        await coordinator.ShutdownAsync();
        trigger.Dispose();
        platform.Dispose();
        tray.Visible = false;
        settingsForm.AllowQuit = true;
        settingsForm.Close();
        composer.Dispose();
        ExitThread();
    }
    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            health.Dispose(); trigger.Dispose(); platform.Dispose(); tray.Dispose(); composer.Dispose(); settingsForm.Dispose();
        }
        base.Dispose(disposing);
    }
}
