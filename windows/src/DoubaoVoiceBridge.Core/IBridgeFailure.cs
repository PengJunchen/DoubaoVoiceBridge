namespace DoubaoVoiceBridge.Core;

/// <summary>Stable diagnostics safe to export without exception messages or paths.</summary>
public interface IBridgeFailure
{
    string Code { get; }
    int NativeError { get; }
}
