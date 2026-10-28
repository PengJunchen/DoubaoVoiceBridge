using System.Text.Json;
using DoubaoVoiceBridge.Core;

var cases = new (string Name, Func<Task> Test)[]
{
    ("manual explicit paste emits exactly one command", ManualPaste),
    ("automatic paste waits for committed stable text", AutoSettle),
    ("composition timeout preserves text", CompositionTimeout),
    ("cancel during synchronization never pastes", CancelDuringSync),
    ("clipboard interference aborts paste", ClipboardChanged),
    ("focus interference aborts paste", TargetChanged),
    ("held modifiers abort paste", ModifiersBlocked),
    ("lost composer never injects voice stop", LostVoiceFocus),
    ("partial paste failure cannot retry", PartialPasteFailure),
    ("cancelled session continuation cannot affect next session", StaleContinuation),
    ("shutdown restores owned clipboard and blocks begin", ShutdownRestore),
    ("short hold released before composer ready is finalized", ReleaseDuringBegin),
    ("unapproved target never shows composer", NoTarget),
    ("settings reject unsafe and unsupported configuration", ValidateSettings),
    ("diagnostics never include transcript or executable path", PrivateLogs),
    ("owned hold keys release after composer focus loss", HoldFocusCleanup),
    ("timeout supports another finalize attempt", RetryFinalize),
    ("native errors retain stable codes without messages", NativeDiagnostics),
    ("uncertain toggle injection is never replayed", UncertainToggle),
    ("cancelled pending composer startup cannot restart voice", CancelPendingStartup),
    ("foreground is checked again after modifiers release", FocusAfterModifierWait),
    ("focus watchdog releases hold and preserves recovery text", HoldWatchdog),
    ("focus watchdog never sends a toggle stop into another app", ToggleWatchdog),
    ("voice watchdog bounds a lost release to five minutes", DurationWatchdog),
    ("manual and paste-test editing are not subject to voice watchdog", ManualWatchdog)
};
var failures = 0;
foreach (var (name, test) in cases)
{
    try { await test(); Console.WriteLine($"PASS {name}"); }
    catch (Exception error) { failures++; Console.WriteLine($"FAIL {name}: {error}"); }
}
Console.WriteLine($"{cases.Length - failures}/{cases.Length} passed");
return failures == 0 ? 0 : 1;

static void Check(bool condition, string message) { if (!condition) throw new Exception(message); }
static Fixture New(BridgeSettings? settings = null) => new(settings ?? new BridgeSettings());
static async Task BeginText(Fixture f, bool test = true)
{
    await f.Coordinator.BeginAsync(test);
    f.Platform.Text = "secret transcript 中文";
}
static async Task ManualPaste()
{
    var f = New(); await BeginText(f);
    var first = f.Coordinator.DeliverAsync();
    await f.Coordinator.DeliverAsync();
    await f.Drain(first);
    await f.Coordinator.DeliverAsync();
    Check(f.Platform.Pastes == 1, "duplicate paste");
    Check(f.Platform.VoiceEvents == 0, "manual injected voice");
    Check(f.Coordinator.State == BridgeState.Idle, "not idle");
    Check(f.Platform.PasteChords.Single() == PasteChord.ControlV, "wrong command");
}
static async Task AutoSettle()
{
    var f = New(new BridgeSettings { AutoPaste = true, VoiceMode = VoiceMode.Hold });
    await BeginText(f, false);
    Check(f.Platform.VoiceDowns == 1, "voice down missing");
    f.Platform.Composing = true;
    var finish = f.Coordinator.FinishAsync();
    await f.Advance(1000);
    Check(f.Platform.Pastes == 0, "composition pasted");
    f.Platform.Composing = false;
    await f.Advance(500);
    Check(f.Platform.Pastes == 0, "did not wait settle");
    await f.Drain(finish);
    Check(f.Platform.VoiceUps == 1 && f.Platform.Pastes == 1, "hold finish failed");
}
static async Task CompositionTimeout()
{
    var f = New(); await BeginText(f, false); f.Platform.Composing = true;
    await f.Drain(f.Coordinator.FinishAsync());
    Check(f.Coordinator.State == BridgeState.Failed, "timeout absent");
    Check(f.Platform.Text.StartsWith("secret"), "text lost");
    await f.Coordinator.DeliverAsync(); Check(f.Platform.Pastes == 0, "manual bypassed composition");
}
static async Task CancelDuringSync()
{
    var f = New(new BridgeSettings { RestoreClipboard = true }); await BeginText(f);
    var paste = f.Coordinator.DeliverAsync();
    Check(f.Platform.Stages == 1, "not staged");
    await f.Coordinator.CancelAsync(); await f.Drain(paste);
    Check(f.Platform.Pastes == 0 && f.Platform.Restores == 1, "cancel cleanup failed");
}
static async Task ClipboardChanged()
{
    var f = New(); await BeginText(f);
    var paste = f.Coordinator.DeliverAsync(); f.Platform.ClipboardText = "later user copy";
    await f.Drain(paste);
    Check(f.Platform.Pastes == 0 && f.Coordinator.State == BridgeState.Failed, "clipboard interference ignored");
}
static async Task TargetChanged()
{
    var f = New(); await BeginText(f);
    var paste = f.Coordinator.DeliverAsync(); f.Platform.TargetForeground = false;
    await f.Drain(paste);
    Check(f.Platform.Pastes == 0 && f.Coordinator.State == BridgeState.Failed, "focus interference ignored");
}
static async Task ModifiersBlocked()
{
    var f = New(); await BeginText(f); f.Platform.Modifiers = true;
    await f.Drain(f.Coordinator.DeliverAsync());
    Check(f.Platform.Pastes == 0 && f.Platform.Stages == 0, "held modifiers ignored");
}
static async Task LostVoiceFocus()
{
    var f = New(new BridgeSettings { VoiceMode = VoiceMode.Toggle }); await BeginText(f, false);
    f.Platform.ComposerForeground = false;
    await f.Coordinator.FinishAsync(); await f.Coordinator.CancelAsync();
    Check(f.Platform.VoiceTaps == 1, "stop was injected outside composer");
    Check(f.Platform.Pastes == 0, "pasted outside composer");
}
static async Task PartialPasteFailure()
{
    var f = New(); await BeginText(f); f.Platform.ThrowPaste = true;
    await f.Drain(f.Coordinator.DeliverAsync());
    f.Platform.ComposerForeground = true;
    await f.Coordinator.DeliverAsync();
    Check(f.Platform.Pastes == 1 && f.Coordinator.State == BridgeState.Failed, "repeated uncertain paste");
}
static async Task StaleContinuation()
{
    var f = New(); await BeginText(f);
    var old = f.Coordinator.DeliverAsync(); await f.Coordinator.CancelAsync();
    f.Platform.TargetForeground = true; await BeginText(f);
    var session = f.Coordinator.SessionId;
    await f.Drain(old);
    Check(f.Coordinator.SessionId == session && f.Coordinator.State == BridgeState.Listening, "old continuation touched new state");
    Check(f.Platform.Pastes == 0, "stale paste");
}
static async Task ShutdownRestore()
{
    var f = New(new BridgeSettings { RestoreClipboard = true }); await BeginText(f);
    var paste = f.Coordinator.DeliverAsync();
    await f.Advance(1100); Check(f.Platform.Pastes == 1, "paste not posted");
    await f.Coordinator.ShutdownAsync(); await f.Drain(paste); await f.Coordinator.BeginAsync();
    Check(f.Platform.Restores == 1 && f.Coordinator.State == BridgeState.Idle, "shutdown cleanup failed");
}
static async Task ReleaseDuringBegin()
{
    var f = New(new BridgeSettings { VoiceMode = VoiceMode.Hold });
    f.Platform.ShowGate = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
    var begin = f.Coordinator.BeginAsync(); await f.Coordinator.FinishAsync();
    f.Platform.ShowGate.SetResult();
    await Task.Delay(5); f.Platform.Text = "dictation";
    await f.Drain(begin);
    Check(f.Platform.VoiceDowns == 1 && f.Platform.VoiceUps == 1, "short hold left voice active");
    Check(f.Coordinator.State == BridgeState.Finalizing, "did not finalize");
}
static async Task NoTarget()
{
    var f = New(); f.Platform.HasTarget = false; await f.Coordinator.BeginAsync();
    Check(f.Platform.Shows == 0 && f.Coordinator.State == BridgeState.Idle, "unapproved target admitted");
}
static Task ValidateSettings()
{
    Check(SettingsValidator.Validate(new BridgeSettings()).Count == 0, "defaults invalid");
    Check(SettingsValidator.Validate(new BridgeSettings { TriggerKey = 13 }).Count > 0, "Enter trigger allowed");
    Check(SettingsValidator.Validate(new BridgeSettings { VoiceKey = 13 }).Count > 0, "Enter voice allowed");
    Check(SettingsValidator.Validate(new BridgeSettings { VoiceModifiers = null! }).Count > 0, "null modifier accepted");
    Check(SettingsValidator.Validate(new BridgeSettings { SyncDelayMs = -1 }).Count > 0, "bad timeout accepted");
    Check(SettingsValidator.Validate(new BridgeSettings { SchemaVersion = 2 }).Count > 0, "future settings accepted");
    return Task.CompletedTask;
}
static async Task PrivateLogs()
{
    var f = New(); await BeginText(f); await f.Drain(f.Coordinator.DeliverAsync());
    var logs = string.Join('\n', f.Log.Entries);
    Check(!logs.Contains("secret") && !logs.Contains("PrivateFolder"), "private data logged");
    Check(logs.Contains("paste.command_posted"), "paste log absent");
}

static async Task HoldFocusCleanup()
{
    var f = New(new BridgeSettings { VoiceMode = VoiceMode.Hold }); await BeginText(f, false);
    f.Platform.ComposerForeground = false; await f.Coordinator.CancelAsync();
    Check(f.Platform.VoiceUps == 1, "owned keyup cleanup missing after focus loss");
}
static async Task RetryFinalize()
{
    var f = New(); await BeginText(f, false); f.Platform.Composing = true;
    await f.Drain(f.Coordinator.FinishAsync());
    f.Platform.Composing = false; await f.Drain(f.Coordinator.FinishAsync());
    Check(f.Coordinator.State == BridgeState.Finalizing, "retry did not settle");
    await f.Drain(f.Coordinator.DeliverAsync()); Check(f.Platform.Pastes == 1, "retry did not deliver");
}
static async Task NativeDiagnostics()
{
    var f = New(); await BeginText(f); f.Platform.ThrowNative = true;
    await f.Drain(f.Coordinator.DeliverAsync());
    var logs = string.Join('\n', f.Log.Entries);
    Check(logs.Contains("native_fake") && logs.Contains("1234") && !logs.Contains("private error detail"), "native diagnostics missing or leaking");
}
static async Task UncertainToggle()
{
    var f = New(new BridgeSettings { VoiceMode = VoiceMode.Toggle }); f.Platform.ThrowVoiceTap = true;
    await f.Coordinator.BeginAsync();
    f.Platform.ThrowVoiceTap = false; await f.Coordinator.FinishAsync(); await f.Coordinator.CancelAsync();
    Check(f.Platform.VoiceTaps == 1, "uncertain start toggle replayed");
    var g = New(new BridgeSettings { VoiceMode = VoiceMode.Toggle }); await BeginText(g, false);
    g.Platform.ThrowVoiceTap = true; await g.Coordinator.FinishAsync();
    g.Platform.ThrowVoiceTap = false; await g.Coordinator.FinishAsync(); await g.Coordinator.CancelAsync();
    Check(g.Platform.VoiceTaps == 2 && g.Platform.Pastes == 0, "uncertain stop toggle replayed");
}

static async Task CancelPendingStartup()
{
    var f = New(new BridgeSettings { VoiceMode = VoiceMode.Hold });
    f.Platform.ShowGate = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
    var oldGate = f.Platform.ShowGate;
    var old = f.Coordinator.BeginAsync();
    await f.Coordinator.CancelAsync();
    f.Platform.ShowGate = null;
    f.Platform.TargetForeground = true;
    await f.Coordinator.BeginAsync(pasteTest: true);
    var session = f.Coordinator.SessionId;
    oldGate.SetResult();
    await f.Drain(old);
    Check(f.Coordinator.State == BridgeState.Listening && f.Coordinator.SessionId == session, "cancelled startup changed new session");
    Check(f.Platform.VoiceDowns == 0, "cancelled startup injected voice");
}
static async Task FocusAfterModifierWait()
{
    var f = New(); await BeginText(f);
    var paste = f.Coordinator.DeliverAsync();
    f.Platform.Modifiers = true;
    await f.Advance(1100);
    Check(f.Platform.Pastes == 0 && f.Coordinator.State == BridgeState.Delivering, "did not wait modifiers");
    f.Platform.TargetForeground = false;
    f.Platform.Modifiers = false;
    await f.Drain(paste);
    Check(f.Platform.Pastes == 0 && f.Coordinator.State == BridgeState.Failed, "focus was not rechecked after modifier wait");
}

static async Task HoldWatchdog()
{
    var f = New(new BridgeSettings { VoiceMode = VoiceMode.Hold }); await BeginText(f, false);
    f.Platform.ComposerForeground = false; await f.Coordinator.CheckHealthAsync();
    Check(f.Platform.VoiceUps == 1 && f.Coordinator.State == BridgeState.Failed, "watchdog did not release hold");
    Check(f.Platform.Text.StartsWith("secret") && f.Platform.Shows == 1 && !f.Platform.ComposerForeground, "watchdog lost text or activated composer");
    await f.Coordinator.CheckHealthAsync(); Check(f.Platform.VoiceUps == 1, "watchdog repeated cleanup");
    f.Platform.ComposerForeground = true;
    await f.Drain(f.Coordinator.FinishAsync()); await f.Drain(f.Coordinator.DeliverAsync());
    Check(f.Platform.Pastes == 1, "watchdog recovery did not permit explicit delivery");
}
static async Task ToggleWatchdog()
{
    var f = New(new BridgeSettings { VoiceMode = VoiceMode.Toggle }); await BeginText(f, false);
    f.Platform.ComposerForeground = false; await f.Coordinator.CheckHealthAsync();
    Check(f.Platform.VoiceTaps == 1 && f.Coordinator.State == BridgeState.Failed, "watchdog injected foreign stop");
    f.Platform.ComposerForeground = true;
    await f.Coordinator.FinishAsync(); await f.Coordinator.DeliverAsync();
    Check(f.Platform.Pastes == 0 && f.Platform.VoiceTaps == 1, "uncertain recording was allowed to continue");
    await f.Coordinator.CancelAsync();
    Check(f.Platform.VoiceTaps == 1 && f.Platform.VoiceUps == 1, "cancel replayed toggle or skipped keyup cleanup");
}
static async Task DurationWatchdog()
{
    var f = New(new BridgeSettings { VoiceMode = VoiceMode.Hold }); await BeginText(f, false);
    f.Clock.Advance(TimeSpan.FromMinutes(5) - TimeSpan.FromMilliseconds(1));
    await f.Coordinator.CheckHealthAsync();
    Check(f.Coordinator.State == BridgeState.Listening, "watchdog expired early");
    f.Clock.Advance(TimeSpan.FromMilliseconds(1)); await f.Coordinator.CheckHealthAsync();
    Check(f.Coordinator.State == BridgeState.Failed && f.Platform.VoiceUps == 1 && f.Platform.Pastes == 0, "duration watchdog failed");
}
static async Task ManualWatchdog()
{
    var f = New(); await BeginText(f, false); f.Platform.ComposerForeground = false;
    f.Clock.Advance(TimeSpan.FromMinutes(10)); await f.Coordinator.CheckHealthAsync();
    Check(f.Coordinator.State == BridgeState.Listening && f.Platform.VoiceEvents == 0, "manual session changed by synthetic watchdog");
    var g = New(new BridgeSettings { VoiceMode = VoiceMode.Hold }); await BeginText(g, true);
    g.Platform.ComposerForeground = false; g.Clock.Advance(TimeSpan.FromMinutes(10)); await g.Coordinator.CheckHealthAsync();
    Check(g.Coordinator.State == BridgeState.Listening && g.Platform.VoiceEvents == 0, "paste test changed by synthetic watchdog");
}

sealed class Fixture
{
    public FakePlatform Platform { get; } = new();
    public FakeLog Log { get; } = new();
    public ManualClock Clock { get; } = new();
    public BridgeCoordinator Coordinator { get; }
    public Fixture(BridgeSettings settings) => Coordinator = new(settings, Platform, Log, Clock);
    public async Task Advance(int milliseconds)
    {
        for (var elapsed = 0; elapsed < milliseconds; elapsed += 25)
        { Clock.Advance(TimeSpan.FromMilliseconds(25)); await Task.Delay(1); }
    }
    public async Task Drain(Task task)
    {
        for (var i = 0; !task.IsCompleted && i < 3000; i++) { Clock.Advance(TimeSpan.FromMilliseconds(25)); await Task.Delay(1); }
        CheckCompleted(task); await task;
    }
    private static void CheckCompleted(Task task) { if (!task.IsCompleted) throw new Exception("virtual-time task did not complete"); }
}
sealed class FakeLog : IBridgeLog
{
    public List<string> Entries { get; } = [];
    public void Write(string eventName, string? sessionId = null, object? fields = null) => Entries.Add(JsonSerializer.Serialize(new { eventName, sessionId, fields }));
}
sealed class FakePlatform : IBridgePlatform
{
    public bool HasTarget = true, TargetForeground = true, ComposerForeground, Composing, Modifiers, ThrowPaste, ThrowNative, ThrowVoiceTap;
    public string Text = "", ClipboardText = "";
    public int Pastes, Stages, Restores, Shows, VoiceDowns, VoiceUps, VoiceTaps;
    public int VoiceEvents => VoiceDowns + VoiceUps + VoiceTaps;
    public List<PasteChord> PasteChords { get; } = [];
    public TaskCompletionSource? ShowGate;
    public TargetWindow? CaptureTarget() => HasTarget && TargetForeground ? new(123, 456, 789, @"C:\PrivateFolder\UU.exe") : null;
    public bool IsTargetForeground(TargetWindow target) => TargetForeground;
    public Task<bool> ActivateTargetAsync(TargetWindow target, CancellationToken cancellationToken) { ComposerForeground = false; TargetForeground = true; return Task.FromResult(true); }
    public async Task ShowComposerAsync(CancellationToken cancellationToken) { Shows++; Text = ""; ComposerForeground = true; if (ShowGate is not null) await ShowGate.Task.WaitAsync(cancellationToken); }
    public void HideComposer() => ComposerForeground = false;
    public TranscriptSnapshot ReadTranscript() => new(Text, Composing, ComposerForeground);
    public bool IsComposerForeground => ComposerForeground;
    public bool ModifiersDown => Modifiers;
    public void VoiceDown(BridgeSettings settings) => VoiceDowns++;
    public void VoiceUp(BridgeSettings settings) => VoiceUps++;
    public void VoiceTap(BridgeSettings settings) { VoiceTaps++; if (ThrowVoiceTap) throw new FakeNativeError(); }
    public ClipboardLease StageClipboard(string text, bool captureSnapshot) { Stages++; if (ThrowNative) throw new FakeNativeError(); ClipboardText = text; return new(1, captureSnapshot ? "backup" : null); }
    public bool ClipboardContains(string text) => ClipboardText == text;
    public bool RestoreClipboard(ClipboardLease lease) { Restores++; return true; }
    public void Paste(PasteChord chord) { Pastes++; PasteChords.Add(chord); if (ThrowPaste) throw new InvalidOperationException("private exception content"); }
}
sealed class ManualClock : TimeProvider
{
    private long _ticks;
    private readonly List<ManualTimer> _timers = [];
    public override long TimestampFrequency => TimeSpan.TicksPerSecond;
    public override long GetTimestamp() => _ticks;
    public override DateTimeOffset GetUtcNow() => DateTimeOffset.UnixEpoch.AddTicks(_ticks);
    public override ITimer CreateTimer(TimerCallback callback, object? state, TimeSpan dueTime, TimeSpan period)
    {
        var timer = new ManualTimer(this, callback, state); timer.Change(dueTime, period); lock (_timers) _timers.Add(timer); return timer;
    }
    public void Advance(TimeSpan duration)
    {
        _ticks += duration.Ticks;
        ManualTimer[] timers; lock (_timers) timers = _timers.ToArray();
        foreach (var timer in timers) timer.Tick(_ticks);
    }
    sealed class ManualTimer(ManualClock owner, TimerCallback callback, object? state) : ITimer
    {
        private long _next = long.MaxValue, _period;
        private bool _disposed;
        public bool Change(TimeSpan dueTime, TimeSpan period)
        { _next = dueTime == Timeout.InfiniteTimeSpan ? long.MaxValue : owner._ticks + dueTime.Ticks; _period = period.Ticks; return !_disposed; }
        public void Tick(long now)
        { if (_disposed || now < _next) return; _next = _period > 0 ? now + _period : long.MaxValue; callback(state); }
        public void Dispose() => _disposed = true;
        public ValueTask DisposeAsync() { Dispose(); return ValueTask.CompletedTask; }
    }
}

sealed class FakeNativeError : Exception, IBridgeFailure
{
    public string Code => "native_fake";
    public int NativeError => 1234;
    public override string Message => "private error detail";
}
