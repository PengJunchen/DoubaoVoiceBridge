using System.Runtime.InteropServices;
using DoubaoVoiceBridge.Core;

namespace DoubaoVoiceBridge.Windows.Native;

// Reserve a single F-key only in an enrolled window. No modifier/key chord reconstruction is needed.
public sealed class GlobalTrigger : IDisposable
{
    private readonly Func<BridgeSettings> _settings;
    private readonly Func<bool> _canBegin;
    private readonly Func<bool> _isApprovedForeground;
    private readonly Action _pressed;
    private readonly Action _released;
    private readonly IBridgeLog _log;
    private readonly NativeMethods.HookProc _callback;
    private nint _hook;
    private int _ownedKey;
    public bool Installed => _hook != 0;
    public bool Held => _ownedKey != 0;
    public int CallbackFailures { get; private set; }

    // Actions must enqueue to the UI and return immediately. The callback does no logging or process lookup.
    public GlobalTrigger(Func<BridgeSettings> settings, Func<bool> canBegin, Func<bool> isApprovedForeground,
        Action pressed, Action released, IBridgeLog log)
    {
        _settings = settings;
        _canBegin = canBegin;
        _isApprovedForeground = isApprovedForeground;
        _pressed = pressed;
        _released = released;
        _log = log;
        _callback = Callback;
        _hook = NativeMethods.SetWindowsHookEx(NativeMethods.WhKeyboardLl, _callback, NativeMethods.GetModuleHandle(null), 0);
        if (_hook == 0) throw new NativeBridgeException("keyboard_hook_install_failed", Marshal.GetLastWin32Error());
        _log.Write("native.hook_installed");
    }

    private nint Callback(int code, nint wParam, nint lParam)
    {
        if (code < 0) return NativeMethods.CallNextHookEx(_hook, code, wParam, lParam);
        var data = Marshal.PtrToStructure<NativeMethods.KeyboardHookData>(lParam);
        if ((data.Flags & 0x12) != 0) return NativeMethods.CallNextHookEx(_hook, code, wParam, lParam); // all injected, including lower-integrity
        var message = unchecked((uint)wParam);
        var down = message is 0x100 or 0x104;
        var up = message is 0x101 or 0x105;
        if (!down && !up) return NativeMethods.CallNextHookEx(_hook, code, wParam, lParam);
        var swallowed = false;
        try
        {
            if (_ownedKey != 0 && data.VirtualKey == _ownedKey)
            {
                swallowed = true;
                if (up)
                {
                    _ownedKey = 0;
                    _released();
                }
                return 1; // suppress auto-repeat and corresponding physical key-up even after focus change
            }
            var key = _settings().TriggerKey;
            if (_ownedKey == 0 && down && key is >= 0x70 and <= 0x87 && data.VirtualKey == key && !AnyModifierDown() && _canBegin() && _isApprovedForeground())
            {
                _ownedKey = key;
                _pressed();
                return 1;
            }
        }
        catch
        {
            CallbackFailures++;
            // Do not let managed exceptions escape the unmanaged callback or write logs on the hook path.
            if (swallowed || _ownedKey == data.VirtualKey) return 1;
        }
        return NativeMethods.CallNextHookEx(_hook, code, wParam, lParam);
    }

    private static bool AnyModifierDown()
    {
        foreach (var key in new[] { 0x10, 0x11, 0x12, 0x5B, 0x5C })
            if ((NativeMethods.GetAsyncKeyState(key) & 0x8000) != 0) return true;
        return false;
    }

    public void Dispose()
    {
        if (_hook == 0) return;
        var removed = NativeMethods.UnhookWindowsHookEx(_hook);
        _hook = 0;
        _log.Write("native.hook_removed", fields: new { removed, callbackFailures = CallbackFailures, keyHeld = _ownedKey != 0 });
        GC.KeepAlive(_callback);
    }
}
