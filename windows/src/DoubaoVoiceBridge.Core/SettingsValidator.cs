namespace DoubaoVoiceBridge.Core;

public static class SettingsValidator
{
    public static IReadOnlyList<string> Validate(BridgeSettings settings)
    {
        var errors = new List<string>();
        if (settings.SchemaVersion != 1) errors.Add("设置版本不受支持");
        if (settings.TriggerKey is < 0x70 or > 0x87) errors.Add("远控触发键必须是 F1–F24");
        if (!Enum.IsDefined(settings.VoiceMode)) errors.Add("豆包启动方式无效");
        if (!Enum.IsDefined(settings.PasteChord)) errors.Add("粘贴键无效");
        if (settings.VoiceKey is < 1 or > 254 || settings.VoiceKey is 0x0D or 0x09 or 0x1B or 0x5B or 0x5C)
            errors.Add("豆包主键不能是 Enter、Tab、Esc 或 Windows 键");
        if (settings.VoiceKey == settings.TriggerKey) errors.Add("豆包主键不能与远控触发键相同");
        if (settings.VoiceModifiers is null || settings.VoiceModifiers.Any(k => !IsModifier(k)) ||
            settings.VoiceModifiers.Distinct().Count() != settings.VoiceModifiers.Length ||
            settings.VoiceModifiers.Contains(settings.VoiceKey)) errors.Add("豆包修饰键无效或重复");
        if (settings.SyncDelayMs is < 450 or > 10000) errors.Add("同步等待必须在 450–10000 毫秒之间");
        if (settings.RestoreDelayMs is < 2000 or > 30000) errors.Add("剪贴板恢复等待必须在 2000–30000 毫秒之间");
        if (settings.SettleMs is < 350 or > 3000) errors.Add("文字稳定等待必须在 350–3000 毫秒之间");
        if (settings.FinalizeTimeoutMs < settings.SettleMs + 450 || settings.FinalizeTimeoutMs > 60000)
            errors.Add("识别超时必须大于稳定等待加 450 毫秒且不超过 60000 毫秒");
        return errors;
    }

    private static bool IsModifier(int key) => key is 0x10 or 0x11 or 0x12 or >= 0xA0 and <= 0xA5;
}
