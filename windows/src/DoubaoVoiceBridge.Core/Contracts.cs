namespace DoubaoVoiceBridge.Core;

public enum VoiceMode { Hold, Toggle, Manual }
public enum PasteChord { ControlV, WindowsV, AltV }
public enum BridgeState { Idle, Listening, Finalizing, Delivering, Failed }

public sealed record BridgeSettings
{
    public int SchemaVersion { get; init; } = 1;
    public int TriggerKey { get; init; } = 0x77; // F8, reserved exclusively inside enrolled UU windows
    public int VoiceKey { get; init; } = 0x20; // Space
    public int[] VoiceModifiers { get; init; } = [0xA4]; // Left Alt
    public VoiceMode VoiceMode { get; init; } = VoiceMode.Manual;
    public PasteChord PasteChord { get; init; } = PasteChord.ControlV;
    public int SyncDelayMs { get; init; } = 1000;
    public int RestoreDelayMs { get; init; } = 3000;
    public int SettleMs { get; init; } = 700;
    public int FinalizeTimeoutMs { get; init; } = 12000;
    public bool AutoPaste { get; init; } = false;
    public bool RestoreClipboard { get; init; } = false;
    public string? ApprovedExecutablePath { get; init; }
}

// Window identity includes PID birth time and executable path to reject handle/PID reuse.
public sealed record TargetWindow(nint Handle, int ProcessId, long ProcessStartTicks, string ExecutablePath);
public sealed record TranscriptSnapshot(string Text, bool IsComposing, bool IsFocused);
public sealed record ClipboardLease(uint Sequence, object? Snapshot);

public interface IBridgePlatform
{
    TargetWindow? CaptureTarget();
    bool IsTargetForeground(TargetWindow target);
    Task<bool> ActivateTargetAsync(TargetWindow target, CancellationToken cancellationToken);
    Task ShowComposerAsync(CancellationToken cancellationToken);
    void HideComposer();
    TranscriptSnapshot ReadTranscript();
    bool IsComposerForeground { get; }
    bool ModifiersDown { get; }
    void VoiceDown(BridgeSettings settings);
    void VoiceUp(BridgeSettings settings);
    void VoiceTap(BridgeSettings settings);
    ClipboardLease StageClipboard(string text, bool captureSnapshot);
    bool ClipboardContains(string text);
    bool RestoreClipboard(ClipboardLease lease);
    void Paste(PasteChord chord);
}

// Fields must contain metadata only, never transcript, clipboard, titles, paths or raw exception messages.
public interface IBridgeLog
{
    void Write(string eventName, string? sessionId = null, object? fields = null);
}
