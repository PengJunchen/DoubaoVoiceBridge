using System.Runtime.InteropServices;
using System.Text;
using DoubaoVoiceBridge.Core;

namespace DoubaoVoiceBridge.Windows.Native;

// All read/compare/write operations are serialized under OpenClipboard on the UI STA.
// We restore only byte-backed, bounded formats; unsupported snapshots fail before EmptyClipboard.
internal sealed class ClipboardStore : IDisposable
{
    private const uint UnicodeText = 13;
    private const int MaxBytes = 8 * 1024 * 1024;
    private readonly NativeWindow _owner = new();
    private readonly HashSet<uint> _safeFormats;
    private sealed record Entry(uint Format, byte[] Bytes);
    private sealed record Snapshot(List<Entry> Entries, string StagedText);
    internal sealed record PublicationDiagnostics(uint WritingSequence, uint PublishedSequence, bool OwnerMatches, bool TextMatches);
    internal PublicationDiagnostics? LastPublication { get; private set; }

    internal ClipboardStore()
    {
        _owner.CreateHandle(new CreateParams { Caption = "DoubaoVoiceBridge.Clipboard", Parent = new nint(-3) }); // HWND_MESSAGE
        _safeFormats = [1, 7, UnicodeText, 16]; // text, OEM text, Unicode text, locale; all HGLOBAL-backed
        foreach (var name in new[] { "HTML Format", "Rich Text Format", "CanIncludeInClipboardHistory", "CanUploadToCloudClipboard", "ExcludeClipboardContentFromMonitorProcessing" })
        {
            var format = NativeMethods.RegisterClipboardFormat(name);
            if (format != 0) _safeFormats.Add(format);
        }
    }

    private IDisposable Enter()
    {
        if (Thread.CurrentThread.GetApartmentState() != ApartmentState.STA) throw new NativeBridgeException("clipboard_requires_sta");
        for (var attempt = 0; attempt < 12; attempt++)
        {
            if (NativeMethods.OpenClipboard(_owner.Handle)) return new ClipboardLock();
            Thread.Sleep(8);
        }
        throw new NativeBridgeException("clipboard_busy", Marshal.GetLastWin32Error());
    }
    private sealed class ClipboardLock : IDisposable { public void Dispose() => NativeMethods.CloseClipboard(); }

    internal ClipboardLease Stage(string text, bool captureSnapshot)
    {
        if (string.IsNullOrEmpty(text)) throw new NativeBridgeException("clipboard_empty_transcript");
        if (text.Length > (MaxBytes / 2) - 1) throw new NativeBridgeException("clipboard_transcript_too_large");
        if (text.Contains('\0')) throw new NativeBridgeException("clipboard_transcript_contains_null");
        var bytes = Encoding.Unicode.GetBytes(text + '\0');
        if (bytes.Length > MaxBytes) throw new NativeBridgeException("clipboard_transcript_too_large");
        var memory = Allocate(bytes);
        LastPublication = null;
        uint writingSequence = 0;
        List<Entry>? entries = null;
        try
        {
            using (var clipboard = Enter())
            {
                entries = captureSnapshot ? CaptureEntries() : null;
                if (!NativeMethods.EmptyClipboard()) throw new NativeBridgeException("clipboard_clear_failed", Marshal.GetLastWin32Error());
                if (NativeMethods.SetClipboardData(UnicodeText, memory) == 0)
                {
                    var error = Marshal.GetLastWin32Error();
                    if (entries is not null)
                    {
                        try { RestoreEntries(entries); }
                        catch (NativeBridgeException) { throw new NativeBridgeException("clipboard_write_and_rollback_failed", error); }
                    }
                    throw new NativeBridgeException("clipboard_write_failed", error);
                }
                memory = 0; // ownership transferred to Windows
                writingSequence = NativeMethods.GetClipboardSequenceNumber();
            } // Publish first. Windows can finish clipboard bookkeeping when the writer closes it.

            // A sequence read inside the writing transaction can precede publication. Reopen after
            // CloseClipboard and prove ownership + payload under this lock before claiming a lease.
            // If another app copied even identical text in between, its different owner fails closed.
            using var publishedClipboard = Enter();
            var ownerMatches = NativeMethods.GetClipboardOwner() == _owner.Handle;
            var textMatches = string.Equals(ReadText(), text, StringComparison.Ordinal);
            var sequence = NativeMethods.GetClipboardSequenceNumber();
            LastPublication = new PublicationDiagnostics(writingSequence, sequence, ownerMatches, textMatches);
            if (!ownerMatches || !textMatches) throw new NativeBridgeException("clipboard_changed_after_staging");
            if (sequence == 0) throw new NativeBridgeException("clipboard_sequence_unavailable");
            return new ClipboardLease(sequence, entries is null ? null : new Snapshot(entries, text));
        }
        finally { if (memory != 0) NativeMethods.GlobalFree(memory); }
    }

    internal sealed record LeaseDiagnostics(uint LeaseSequence, uint CurrentSequence, bool OwnerMatches, bool TextMatches, bool HasSnapshot);

    internal LeaseDiagnostics InspectLease(ClipboardLease lease)
    {
        using var clipboard = Enter();
        var ownerMatches = NativeMethods.GetClipboardOwner() == _owner.Handle;
        var textMatches = lease.Snapshot is Snapshot snapshot && string.Equals(ReadText(), snapshot.StagedText, StringComparison.Ordinal);
        return new LeaseDiagnostics(lease.Sequence, NativeMethods.GetClipboardSequenceNumber(), ownerMatches, textMatches, lease.Snapshot is Snapshot);
    }

    internal bool Contains(string text)
    {
        using var clipboard = Enter();
        return string.Equals(ReadText(), text, StringComparison.Ordinal);
    }

    internal bool Restore(ClipboardLease lease)
    {
        if (lease.Snapshot is not Snapshot snapshot) return false;
        using var clipboard = Enter();
        if (NativeMethods.GetClipboardSequenceNumber() != lease.Sequence || NativeMethods.GetClipboardOwner() != _owner.Handle ||
            !string.Equals(ReadText(), snapshot.StagedText, StringComparison.Ordinal)) return false;
        RestoreEntries(snapshot.Entries);
        return true;
    }

    private List<Entry> CaptureEntries()
    {
        var entries = new List<Entry>();
        uint format = 0;
        var total = 0;
        while ((format = NativeMethods.EnumClipboardFormats(format)) != 0)
        {
            if (!_safeFormats.Contains(format)) throw new NativeBridgeException("clipboard_snapshot_unsupported_format");
            var memory = NativeMethods.GetClipboardData(format);
            var bytes = CopyMemory(memory);
            total = checked(total + bytes.Length);
            if (total > MaxBytes || entries.Count >= 32) throw new NativeBridgeException("clipboard_snapshot_too_large");
            entries.Add(new Entry(format, bytes));
        }
        // Enumeration returning zero with last-error nonzero is a failure, not end-of-list.
        var error = Marshal.GetLastWin32Error();
        if (error != 0) throw new NativeBridgeException("clipboard_enumeration_failed", error);
        return entries;
    }

    private static byte[] CopyMemory(nint memory)
    {
        if (memory == 0) throw new NativeBridgeException("clipboard_data_unavailable", Marshal.GetLastWin32Error());
        var size = NativeMethods.GlobalSize(memory);
        if (size == 0 || size > MaxBytes) throw new NativeBridgeException("clipboard_data_size_unsupported");
        var pointer = NativeMethods.GlobalLock(memory);
        if (pointer == 0) throw new NativeBridgeException("clipboard_lock_failed", Marshal.GetLastWin32Error());
        try
        {
            var bytes = new byte[checked((int)size)];
            Marshal.Copy(pointer, bytes, 0, bytes.Length);
            return bytes;
        }
        finally { NativeMethods.GlobalUnlock(memory); }
    }

    private static string? ReadText()
    {
        var memory = NativeMethods.GetClipboardData(UnicodeText);
        if (memory == 0) return null;
        var bytes = CopyMemory(memory);
        if (bytes.Length % 2 != 0) return null;
        var value = Encoding.Unicode.GetString(bytes);
        var terminator = value.IndexOf('\0');
        return terminator < 0 ? null : value[..terminator];
    }

    private static nint Allocate(byte[] bytes)
    {
        var memory = NativeMethods.GlobalAlloc(0x0042, checked((nuint)bytes.Length)); // GMEM_MOVEABLE | GMEM_ZEROINIT
        if (memory == 0) throw new NativeBridgeException("clipboard_allocation_failed", Marshal.GetLastWin32Error());
        var pointer = NativeMethods.GlobalLock(memory);
        if (pointer == 0)
        {
            NativeMethods.GlobalFree(memory);
            throw new NativeBridgeException("clipboard_allocation_lock_failed", Marshal.GetLastWin32Error());
        }
        try { Marshal.Copy(bytes, 0, pointer, bytes.Length); }
        finally { NativeMethods.GlobalUnlock(memory); }
        return memory;
    }

    private static void RestoreEntries(List<Entry> entries)
    {
        // Allocate everything before clearing the current clipboard, so allocation failure is non-destructive.
        var allocations = new List<(uint Format, nint Memory)>();
        try
        {
            foreach (var entry in entries) allocations.Add((entry.Format, Allocate(entry.Bytes)));
            if (!NativeMethods.EmptyClipboard()) throw new NativeBridgeException("clipboard_restore_clear_failed", Marshal.GetLastWin32Error());
            for (var index = 0; index < allocations.Count; index++)
            {
                var (format, memory) = allocations[index];
                if (NativeMethods.SetClipboardData(format, memory) == 0) throw new NativeBridgeException("clipboard_restore_failed", Marshal.GetLastWin32Error());
                allocations[index] = (format, 0);
            }
        }
        finally { foreach (var allocation in allocations) if (allocation.Memory != 0) NativeMethods.GlobalFree(allocation.Memory); }
    }

    public void Dispose() => _owner.DestroyHandle();
}
