using System.Text;
using System.Runtime.InteropServices;
using DoubaoVoiceBridge.Core;

namespace DoubaoVoiceBridge.Windows.Native;

public interface IComposerHost
{
    Task ShowComposerAsync(CancellationToken cancellationToken);
    void HideComposer();
    TranscriptSnapshot ReadTranscript();
    bool IsComposerForeground { get; }
}

public sealed class NativeBridgePlatform : IBridgePlatform, IDisposable
{
    private readonly Func<BridgeSettings> _settings;
    private readonly IBridgeLog _log;
    private readonly IComposerHost _composer;
    private readonly ClipboardStore _clipboard = new();
    private readonly System.Windows.Forms.Timer _eligibilityTimer;
    private readonly List<int> _ownedVoiceKeys = [];
    private readonly List<int> _ownedPasteKeys = [];
    public Func<string?>? SessionIdProvider { get; set; }
    private TargetWindow? _eligible;
    private TargetWindow? _deliveryTarget;
    private bool _disposed;

    public NativeBridgePlatform(Func<BridgeSettings> settings, IBridgeLog log, IComposerHost composer)
    {
        _settings = settings;
        _log = log;
        _composer = composer;
        _eligibilityTimer = new System.Windows.Forms.Timer { Interval = 250 };
        _eligibilityTimer.Tick += (_, _) => RefreshEligibility();
        RefreshEligibility();
        _eligibilityTimer.Start();
        Write("native.ready", new { pointerBits = IntPtr.Size * 8, inputSize = Marshal.SizeOf<NativeMethods.Input>() });
    }

    // Called from the low-level hook: no process/module or filesystem access here.
    public bool IsApprovedForegroundFast
    {
        get
        {
            var eligible = _eligible;
            if (eligible is null || !PathEquals(eligible.ExecutablePath, _settings().ApprovedExecutablePath)) return false;
            var foreground = NativeMethods.GetForegroundWindow();
            NativeMethods.GetWindowThreadProcessId(foreground, out var pid);
            return foreground == eligible.Handle && pid == eligible.ProcessId;
        }
    }

    private void RefreshEligibility()
    {
        var current = InspectForeground();
        _eligible = current is not null && PathEquals(current.ExecutablePath, _settings().ApprovedExecutablePath) ? current : null;
    }

    public static TargetWindow? InspectForeground() => InspectWindow(NativeMethods.GetForegroundWindow());

    public static bool IsOwnForegroundWindow(nint expectedHandle)
    {
        var foreground = NativeMethods.GetForegroundWindow();
        NativeMethods.GetWindowThreadProcessId(foreground, out var pid);
        return foreground == expectedHandle && pid == Environment.ProcessId;
    }

    private static TargetWindow? InspectWindow(nint window)
    {
        if (window == 0 || !NativeMethods.IsWindow(window)) return null;
        NativeMethods.GetWindowThreadProcessId(window, out var pid);
        if (pid == 0 || pid == Environment.ProcessId) return null;
        try
        {
            // Query-limited-information works across x64/ARM64/WOW64 and avoids module enumeration permissions.
            using var process = NativeMethods.OpenProcess(0x1000, false, pid);
            if (process.IsInvalid) return null;
            var buffer = new StringBuilder(32768);
            uint capacity = 32768;
            if (!NativeMethods.QueryFullProcessImageName(process, 0, buffer, ref capacity) ||
                !NativeMethods.GetProcessTimes(process, out var creation, out _, out _, out _)) return null;
            var path = buffer.ToString();
            if (string.IsNullOrWhiteSpace(path)) return null;
            var target = new TargetWindow(window, checked((int)pid), DateTime.FromFileTimeUtc(creation).Ticks, Path.GetFullPath(path));
            NativeMethods.GetWindowThreadProcessId(window, out var verifiedPid);
            return verifiedPid == pid && NativeMethods.IsWindow(window) ? target : null;
        }
        catch (Exception error) when (error is System.ComponentModel.Win32Exception or InvalidOperationException or ArgumentException or OverflowException or NotSupportedException)
        {
            return null;
        }
    }

    private static bool PathEquals(string? left, string? right) =>
        !string.IsNullOrWhiteSpace(left) && !string.IsNullOrWhiteSpace(right) && string.Equals(left, right, StringComparison.OrdinalIgnoreCase);

    private bool MatchesIdentity(TargetWindow target)
    {
        var actual = InspectWindow(target.Handle);
        return actual is not null && actual.ProcessId == target.ProcessId && actual.ProcessStartTicks == target.ProcessStartTicks &&
            PathEquals(actual.ExecutablePath, target.ExecutablePath) && PathEquals(actual.ExecutablePath, _settings().ApprovedExecutablePath);
    }

    public TargetWindow? CaptureTarget()
    {
        var actual = InspectForeground();
        if (actual is null || !PathEquals(actual.ExecutablePath, _settings().ApprovedExecutablePath)) return null;
        _deliveryTarget = actual;
        return actual;
    }

    public bool IsTargetForeground(TargetWindow target) => NativeMethods.GetForegroundWindow() == target.Handle && MatchesIdentity(target);

    public async Task<bool> ActivateTargetAsync(TargetWindow target, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (!MatchesIdentity(target)) return false;
        _deliveryTarget = target;
        if (IsTargetForeground(target)) return true;
        var before = NativeMethods.GetForegroundWindow();
        NativeMethods.GetWindowThreadProcessId(before, out var beforePid);
        if (before != 0 && before != target.Handle && beforePid != Environment.ProcessId) return false;
        if (NativeMethods.IsIconic(target.Handle)) NativeMethods.ShowWindow(target.Handle, 9); // SW_RESTORE
        // One activation attempt only; never repeatedly steal focus from a new user window.
        var accepted = NativeMethods.SetForegroundWindow(target.Handle);
        Write("native.activation", new { accepted });
        for (var attempt = 0; attempt < 10; attempt++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (IsTargetForeground(target)) return true;
            var foreground = NativeMethods.GetForegroundWindow();
            if (foreground != 0 && foreground != before && foreground != target.Handle) return false;
            await Task.Delay(40, cancellationToken);
        }
        return false;
    }

    public Task ShowComposerAsync(CancellationToken cancellationToken) => _composer.ShowComposerAsync(cancellationToken);
    public void HideComposer() => _composer.HideComposer();
    public TranscriptSnapshot ReadTranscript() => _composer.ReadTranscript();
    public bool IsComposerForeground => _composer.IsComposerForeground;
    public bool ModifiersDown => ModifierKeys.Any(IsKeyDown);
    private static readonly int[] ModifierKeys = [0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0x5B, 0x5C];
    private static bool IsKeyDown(int key) => (NativeMethods.GetAsyncKeyState(key) & 0x8000) != 0;
    public static bool IsBridgeInjectedMessage => unchecked((nuint)NativeMethods.GetMessageExtraInfo()) == NativeMethods.InjectionMarker;

    public void VoiceDown(BridgeSettings settings)
    {
        if (!IsComposerForeground) throw new NativeBridgeException("composer_focus_lost");
        if (_ownedVoiceKeys.Count != 0) throw new NativeBridgeException("voice_keys_already_owned");
        if (ModifiersDown) throw new NativeBridgeException("physical_modifiers_down");
        var keys = settings.VoiceModifiers.Append(settings.VoiceKey).Distinct().ToArray();
        var inputs = keys.Select(key => KeyInput(key, false)).ToArray();
        var sent = NativeMethods.SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<NativeMethods.Input>());
        var nativeError = Marshal.GetLastWin32Error();
        _ownedVoiceKeys.AddRange(keys.Take(checked((int)sent)));
        Write("native.voice_down", new { requested = inputs.Length, sent, nativeError });
        if (sent != inputs.Length)
        {
            try { ReleaseVoiceKeys(); }
            catch (NativeBridgeException error) { Write("native.voice_cleanup_failed", new { error.Code, error.NativeError }); }
            throw new NativeBridgeException("voice_input_partial_or_blocked", nativeError);
        }
    }

    // Cleanup may post key-up only after focus loss. It never starts a new shortcut in another app.
    public void VoiceUp(BridgeSettings settings) => ReleaseVoiceKeys();

    private void ReleaseVoiceKeys() => ReleaseOwnedKeys(_ownedVoiceKeys, "native.voice_up", "voice_release_partial_or_blocked");

    private void ReleaseOwnedKeys(List<int> ownedKeys, string eventName, string failureCode)
    {
        if (ownedKeys.Count == 0) return;
        var inputs = ownedKeys.AsEnumerable().Reverse().Select(key => KeyInput(key, true)).ToArray();
        var sent = NativeMethods.SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<NativeMethods.Input>());
        var nativeError = Marshal.GetLastWin32Error();
        // Keep unsent releases owned so Shutdown/Dispose can try them again.
        for (var index = 0; index < sent && ownedKeys.Count > 0; index++) ownedKeys.RemoveAt(ownedKeys.Count - 1);
        Write(eventName, new { requested = inputs.Length, sent, nativeError });
        if (sent != inputs.Length) throw new NativeBridgeException(failureCode, nativeError);
    }

    public void VoiceTap(BridgeSettings settings)
    {
        VoiceDown(settings);
        try { Thread.Sleep(60); } // A short real dwell lets global IME shortcut handlers observe a tap.
        finally { VoiceUp(settings); } // Only owned key-up cleanup is sent if focus changes during the dwell.
    }

    public ClipboardLease StageClipboard(string text, bool captureSnapshot) => _clipboard.Stage(text, captureSnapshot);
    public bool ClipboardContains(string text) => _clipboard.Contains(text);
    public bool RestoreClipboard(ClipboardLease lease) => _clipboard.Restore(lease);

    public void Paste(PasteChord chord)
    {
        if (_ownedPasteKeys.Count != 0) throw new NativeBridgeException("paste_cleanup_pending_restart_required");
        if (_deliveryTarget is null || !IsTargetForeground(_deliveryTarget)) throw new NativeBridgeException("target_changed_before_input");
        if (ModifiersDown) throw new NativeBridgeException("physical_modifiers_down");
        var modifier = chord switch { PasteChord.ControlV => 0xA2, PasteChord.WindowsV => 0x5B, PasteChord.AltV => 0xA4, _ => throw new NativeBridgeException("invalid_paste_chord") };
        var inputs = new[] { KeyInput(modifier, false), KeyInput(0x56, false), KeyInput(0x56, true), KeyInput(modifier, true) };
        var sent = NativeMethods.SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<NativeMethods.Input>());
        var nativeError = Marshal.GetLastWin32Error();
        Write("native.paste", new { requested = inputs.Length, sent, nativeError, chord = chord.ToString() });
        if (sent != inputs.Length)
        {
            // A partial sequence may already have pasted. Release only our accepted downs; never replay paste.
            if (sent is >= 1 and <= 3) _ownedPasteKeys.Add(modifier);
            if (sent == 2) _ownedPasteKeys.Add(0x56);
            try { ReleaseOwnedKeys(_ownedPasteKeys, "native.paste_cleanup", "paste_cleanup_partial_or_blocked"); }
            catch (NativeBridgeException error) { Write("native.paste_cleanup_failed", new { error.Code, error.NativeError }); }
            throw new NativeBridgeException("paste_partial_or_blocked_no_retry", nativeError);
        }
    }

    private static NativeMethods.Input KeyInput(int key, bool up) => new()
    {
        Type = 1,
        Data = new NativeMethods.InputUnion { Keyboard = new NativeMethods.KeyboardInput
        {
            VirtualKey = checked((ushort)key), Flags = (up ? NativeMethods.KeyUp : 0) | (key is 0xA3 or 0xA5 or 0x5B or 0x5C ? NativeMethods.ExtendedKey : 0),
            ExtraInfo = NativeMethods.InjectionMarker
        } }
    };

    private void Write(string eventName, object? fields = null) => _log.Write(eventName, SessionIdProvider?.Invoke(), fields);

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _eligibilityTimer.Stop();
        _eligibilityTimer.Dispose();
        for (var attempt = 0; attempt < 3 && (_ownedVoiceKeys.Count > 0 || _ownedPasteKeys.Count > 0); attempt++)
        {
            try { ReleaseVoiceKeys(); }
            catch (NativeBridgeException error) { Write("native.shutdown_voice_release_failed", new { error.Code, error.NativeError }); }
            try { ReleaseOwnedKeys(_ownedPasteKeys, "native.shutdown_paste_cleanup", "paste_cleanup_partial_or_blocked"); }
            catch (NativeBridgeException error) { Write("native.shutdown_paste_release_failed", new { error.Code, error.NativeError }); }
            if (_ownedVoiceKeys.Count > 0 || _ownedPasteKeys.Count > 0) Thread.Sleep(20);
        }
        _clipboard.Dispose();
    }
}
