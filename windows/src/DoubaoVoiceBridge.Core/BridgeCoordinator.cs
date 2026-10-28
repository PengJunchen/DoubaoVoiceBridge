namespace DoubaoVoiceBridge.Core;

/// <summary>
/// One local dictation session and at most one paste command. Call on a single UI synchronization
/// context. Every continuation checks its cancellation token before interacting with the desktop.
/// </summary>
public sealed class BridgeCoordinator
{
    private readonly IBridgePlatform _platform;
    private readonly IBridgeLog _log;
    private readonly TimeProvider _clock;
    private CancellationTokenSource? _session;
    private TargetWindow? _target;
    private ClipboardLease? _lease;
    private long _listeningStarted;
    public static TimeSpan MaximumVoiceDuration => TimeSpan.FromMinutes(5);
    private bool _starting, _settling, _ready, _voiceActive, _finishRequested, _pasteAttempted, _shutdown, _voiceUncertain;
    public BridgeSettings Settings { get; }
    public BridgeState State { get; private set; } = BridgeState.Idle;
    public string? SessionId { get; private set; }
    public event Action<string>? Status;
    public event Action<BridgeState>? StateChanged;

    public BridgeCoordinator(BridgeSettings settings, IBridgePlatform platform, IBridgeLog log, TimeProvider? clock = null)
    {
        var errors = SettingsValidator.Validate(settings);
        if (errors.Count > 0) throw new ArgumentException(string.Join("；", errors), nameof(settings));
        Settings = settings with { VoiceModifiers = (int[])settings.VoiceModifiers.Clone() };
        _platform = platform;
        _log = log;
        _clock = clock ?? TimeProvider.System;
    }

    public async Task BeginAsync(bool pasteTest = false)
    {
        if (_shutdown || State != BridgeState.Idle) return;
        _target = _platform.CaptureTarget();
        if (_target is null) { Announce("请先选择已绑定的 UU 远控会话窗口"); return; }
        _session?.Dispose();
        _session = new CancellationTokenSource();
        var token = _session.Token;
        SessionId = Guid.NewGuid().ToString("N")[..12];
        _starting = true;
        _ready = pasteTest;
        _finishRequested = _pasteAttempted = false;
        _listeningStarted = _clock.GetTimestamp();
        SetState(BridgeState.Listening);
        Log("session.begin", new { pasteTest, voiceMode = Settings.VoiceMode.ToString() });
        try
        {
            await _platform.ShowComposerAsync(token);
            token.ThrowIfCancellationRequested();
            if (!_platform.IsComposerForeground) throw new BridgeFault("composer_focus");
            if (!pasteTest && Settings.VoiceMode != VoiceMode.Manual)
            {
                await WaitForModifiersAsync(token);
                RequireComposer();
                // Mark before injection so partial SendInput failures receive conservative cleanup.
                _voiceActive = true;
                if (Settings.VoiceMode == VoiceMode.Hold) _platform.VoiceDown(Settings);
                else
                {
                    try { _platform.VoiceTap(Settings); }
                    catch { _voiceActive = false; _voiceUncertain = true; throw; }
                }
                Log("voice.started");
            }
            Announce(pasteTest ? "输入测试文字，点击粘贴；不会录音或发送消息" :
                Settings.VoiceMode == VoiceMode.Manual ? "请在本机听写框使用豆包语音；结束后点击完成识别" : "正在听写；松开远控触发键完成");
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { return; }
        catch (Exception error) { Fail(error, "无法启动本机听写；请检查豆包快捷键与焦点"); }
        finally { if (!token.IsCancellationRequested) _starting = false; }
        if (!token.IsCancellationRequested && _finishRequested && State == BridgeState.Listening) await FinishAsync();
    }

    public async Task FinishAsync()
    {
        if (_voiceUncertain) { Announce("豆包启动或停止指令可能部分执行；请手动检查录音状态，再取消此会话"); return; }
        if (_starting) { _finishRequested = true; return; }
        if ((State != BridgeState.Listening && State != BridgeState.Failed) || _pasteAttempted || _session is null) return;
        var token = _session.Token;
        SetState(BridgeState.Finalizing);
        _settling = true;
        _ready = false;
        try
        {
            StopVoice();
            RequireComposer();
            Announce("正在等待豆包提交最终文字…");
            var started = _clock.GetTimestamp();
            var changed = started;
            string? previous = null;
            var wasComposing = true;
            while (true)
            {
                token.ThrowIfCancellationRequested();
                RequireComposer();
                var snapshot = _platform.ReadTranscript();
                if (!snapshot.IsFocused) throw new BridgeFault("composer_focus");
                var now = _clock.GetTimestamp();
                if (snapshot.Text != previous || snapshot.IsComposing != wasComposing)
                {
                    previous = snapshot.Text;
                    wasComposing = snapshot.IsComposing;
                    changed = now;
                }
                if (!string.IsNullOrWhiteSpace(snapshot.Text) && !snapshot.IsComposing &&
                    _clock.GetElapsedTime(started, now).TotalMilliseconds >= 450 &&
                    _clock.GetElapsedTime(changed, now).TotalMilliseconds >= Settings.SettleMs)
                {
                    _ready = true;
                    Log("transcript.settled", new { lengthBucket = LengthBucket(snapshot.Text.Length) });
                    break;
                }
                if (_clock.GetElapsedTime(started, now).TotalMilliseconds >= Settings.FinalizeTimeoutMs)
                    throw new BridgeFault("transcript_timeout");
                await Delay(50, token);
            }
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { return; }
        catch (Exception error) { Fail(error, "识别未完成或焦点已变化；文字保留，请检查后重新完成识别"); }
        finally { if (!token.IsCancellationRequested) _settling = false; }
        if (!token.IsCancellationRequested && _ready)
        {
            Announce("文字已就绪；点击粘贴到原 UU 会话");
            if (Settings.AutoPaste) await DeliverAsync();
        }
    }

    public async Task DeliverAsync()
    {
        if (_starting || _settling || _voiceActive || _voiceUncertain || _pasteAttempted ||
            State is BridgeState.Idle or BridgeState.Delivering || _session is null || _target is null) return;
        var token = _session.Token;
        var target = _target;
        try
        {
            token.ThrowIfCancellationRequested();
            RequireComposer();
            var snapshot = _platform.ReadTranscript();
            if (snapshot.IsComposing || !snapshot.IsFocused || string.IsNullOrWhiteSpace(snapshot.Text))
                throw new BridgeFault("transcript_uncommitted");
            // An explicit click may approve edited/typed text even after a settle timeout.
            var text = snapshot.Text;
            SetState(BridgeState.Delivering);
            Announce("正在恢复 UU 会话并等待剪贴板同步…");
            await WaitForModifiersAsync(token);
            token.ThrowIfCancellationRequested();
            _platform.HideComposer();
            if (!await _platform.ActivateTargetAsync(target, token)) throw new BridgeFault("target_activation");
            token.ThrowIfCancellationRequested();
            RequireTarget(target);
            _lease = _platform.StageClipboard(text, Settings.RestoreClipboard);
            Log("clipboard.staged", new { lengthBucket = LengthBucket(text.Length), restore = Settings.RestoreClipboard });
            await Delay(Settings.SyncDelayMs, token);
            token.ThrowIfCancellationRequested();
            RequireTarget(target);
            if (!_platform.ClipboardContains(text)) throw new BridgeFault("clipboard_changed");
            await WaitForModifiersAsync(token);
            token.ThrowIfCancellationRequested();
            RequireTarget(target);
            if (!_platform.ClipboardContains(text)) throw new BridgeFault("clipboard_changed");
            // No await between the last guards and the only paste attempt.
            _pasteAttempted = true;
            _platform.Paste(Settings.PasteChord);
            Log("paste.command_posted", new { chord = Settings.PasteChord.ToString() });
            Announce("已向 UU 发送粘贴指令；请核对远端文字，消息需自行发送");
            if (Settings.RestoreClipboard) await Delay(Settings.RestoreDelayMs, token);
            token.ThrowIfCancellationRequested();
            RestoreLease();
            Complete();
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { }
        catch (Exception error)
        {
            RestoreLease();
            Fail(error, _pasteAttempted ? "粘贴指令可能部分执行；请先核对远端，避免重复粘贴。取消后才能新建会话" :
                "已停止粘贴；文字保留。请回到本机听写框检查后重试");
            // Showing a composer clears text by contract, so keep the hidden composer intact.
        }
    }

    /// <summary>
    /// Call from the UI timer. A lost release or desktop switch cannot leave an owned synthetic
    /// hold active indefinitely. This preserves text and performs no window activation.
    /// </summary>
    public Task CheckHealthAsync()
    {
        if (_starting || State != BridgeState.Listening || !_voiceActive || _session is null)
            return Task.CompletedTask;
        var lostFocus = !_platform.IsComposerForeground;
        var expired = _clock.GetElapsedTime(_listeningStarted) >= MaximumVoiceDuration;
        if (!lostFocus && !expired) return Task.CompletedTask;
        var code = lostFocus ? "voice_focus_watchdog" : "voice_duration_watchdog";
        if (Settings.VoiceMode == VoiceMode.Toggle && lostFocus)
        {
            // A stop tap would reach an unrelated application. Require a manual recording check.
            _voiceActive = false;
            _voiceUncertain = true;
            Log("voice.manual_stop_required", new { reason = code });
        }
        else
        {
            try { StopVoice(); }
            catch (Exception error) { LogError("voice.watchdog_stop_failed", error); }
        }
        var message = _voiceUncertain || _voiceActive ?
            "听写已暂停；请手动确认豆包录音和按键已停止，再取消会话。文字仍保留。" :
            expired ? "听写已超过 5 分钟，已结束语音按键操作；文字保留，请检查后完成识别或取消。" :
            "听写焦点已离开，已释放语音按键；文字保留，请返回听写框检查后完成识别或取消。";
        Fail(new BridgeFault(code), message);
        return Task.CompletedTask;
    }

    public Task CancelAsync()
    {
        if (State == BridgeState.Idle) return Task.CompletedTask;
        _session?.Cancel();
        if (_voiceUncertain)
        {
            Announce("已取消；请手动确认本机豆包录音已停止");
            // Failed tap injection may own pending key-ups. Cleanup must never replay a toggle.
            try { _platform.VoiceUp(Settings); }
            catch (Exception error) { LogError("voice.uncertain_key_release_failed", error); }
        }
        try { StopVoice(); }
        catch (Exception error) { LogError("voice.cancel_failed", error); Announce("已取消；请手动确认本机豆包录音已停止"); }
        RestoreLease();
        _platform.HideComposer();
        Log("session.cancelled", new { pasteAttempted = _pasteAttempted });
        Complete();
        return Task.CompletedTask;
    }

    public async Task ShutdownAsync()
    {
        _shutdown = true;
        await CancelAsync();
        RestoreLease();
        _session?.Dispose();
    }

    private async Task WaitForModifiersAsync(CancellationToken token)
    {
        var started = _clock.GetTimestamp();
        while (_platform.ModifiersDown)
        {
            token.ThrowIfCancellationRequested();
            if (_clock.GetElapsedTime(started).TotalMilliseconds >= 1500) throw new BridgeFault("modifiers_active");
            await Delay(25, token);
        }
    }

    private void StopVoice()
    {
        if (!_voiceActive) return;
        // Owned key-up cleanup must run even after a focus change. It never starts a new chord.
        if (Settings.VoiceMode == VoiceMode.Hold) _platform.VoiceUp(Settings);
        else if (Settings.VoiceMode == VoiceMode.Toggle)
        {
            RequireComposer();
            // An uncertain toggle must never be retried: a second tap could start recording again.
            _voiceActive = false;
            try { _platform.VoiceTap(Settings); }
            catch { _voiceUncertain = true; throw; }
        }
        _voiceActive = false;
        Log("voice.stopped");
    }

    private void RestoreLease()
    {
        var lease = _lease;
        _lease = null;
        if (lease is null || !Settings.RestoreClipboard) return;
        try { Log("clipboard.restore", new { restored = _platform.RestoreClipboard(lease) }); }
        catch (Exception error) { LogError("clipboard.restore_failed", error); }
    }
    private void Complete()
    {
        _target = null;
        _starting = _settling = _ready = _finishRequested = _voiceActive = _voiceUncertain = false;
        SetState(BridgeState.Idle);
    }
    private void RequireComposer() { if (!_platform.IsComposerForeground) throw new BridgeFault("composer_focus"); }
    private void RequireTarget(TargetWindow target) { if (!_platform.IsTargetForeground(target)) throw new BridgeFault("target_changed"); }
    private void SetState(BridgeState state) { State = state; Log("session.state", new { state = state.ToString() }); StateChanged?.Invoke(state); }
    private void Fail(Exception error, string message) { LogError("session.failed", error); SetState(BridgeState.Failed); Announce(message); }
    private void LogError(string name, Exception error) => Log(name, new { errorType = error.GetType().Name, code = (error as IBridgeFailure)?.Code, nativeError = (error as IBridgeFailure)?.NativeError });
    private void Log(string name, object? fields = null) => _log.Write(name, SessionId, fields);
    private void Announce(string message) => Status?.Invoke(message);
    private Task Delay(int milliseconds, CancellationToken token) => Task.Delay(TimeSpan.FromMilliseconds(milliseconds), _clock, token);
    private static string LengthBucket(int length) => length switch { 0 => "empty", <= 4 => "1-4", <= 16 => "5-16", <= 64 => "17-64", _ => "65+" };
    private sealed class BridgeFault(string code) : Exception, IBridgeFailure { public string Code { get; } = code; public int NativeError => 0; }
}
