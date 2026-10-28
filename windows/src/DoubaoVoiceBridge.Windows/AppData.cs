using System.IO.Compression;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Text.Json.Serialization;
using DoubaoVoiceBridge.Core;

namespace DoubaoVoiceBridge.Windows;

internal static class AppData
{
    public static readonly string Root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "DoubaoVoiceBridge");
    public static readonly string SettingsPath = Path.Combine(Root, "settings.json");
    public static readonly JsonSerializerOptions Json = new() { WriteIndented = true, Converters = { new JsonStringEnumConverter() } };
    public static string? LoadWarning { get; private set; }

    public static BridgeSettings Load(IBridgeLog log, string? settingsPath = null)
    {
        LoadWarning = null;
        var path = Path.GetFullPath(settingsPath ?? SettingsPath);
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        if (!File.Exists(path)) return new();
        try
        {
            var value = JsonSerializer.Deserialize<BridgeSettings>(File.ReadAllText(path), Json) ?? throw new InvalidDataException();
            var errors = SettingsValidator.Validate(value);
            if (errors.Count != 0) throw new InvalidDataException();
            return value;
        }
        catch (Exception ex) when (ex is IOException or InvalidDataException or JsonException or UnauthorizedAccessException or ArgumentException)
        {
            LoadWarning = "配置无法读取或格式不兼容，已使用安全默认值。原文件尚未覆盖，请检查设置后保存。";
            log.Write("settings.load_failed", fields: new { errorType = ex.GetType().Name });
            return new();
        }
    }

    public static void Save(BridgeSettings value, string? settingsPath = null)
    {
        var errors = SettingsValidator.Validate(value);
        if (errors.Count != 0) throw new InvalidDataException(string.Join("\n", errors));
        var path = Path.GetFullPath(settingsPath ?? SettingsPath);
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var temp = path + ".tmp";
        File.WriteAllText(temp, JsonSerializer.Serialize(value, Json));
        File.Move(temp, path, true);
    }

    public static object SafeSettings(BridgeSettings s) => new
    {
        s.SchemaVersion, s.TriggerKey, s.VoiceKey, s.VoiceModifiers, s.VoiceMode, s.PasteChord,
        s.SyncDelayMs, s.RestoreDelayMs, s.SettleMs, s.FinalizeTimeoutMs,
        s.AutoPaste, s.RestoreClipboard, targetEnrolled = !string.IsNullOrWhiteSpace(s.ApprovedExecutablePath)
    };
}

internal sealed class DiagnosticLog : IBridgeLog, IDisposable
{
    private readonly object gate = new();
    private readonly string folder;
    private readonly string runId = Guid.NewGuid().ToString("N");
    private string currentPath = "";
    private int part;
    private bool disposed;
    public bool HasWriteFailure { get; private set; }
    private const long MaxBytes = 2 * 1024 * 1024;
    private const int Retention = 8;

    public DiagnosticLog(string? dataRoot = null)
    {
        folder = Path.Combine(dataRoot ?? AppData.Root, "logs");
        Write("app.start", fields: new
        {
            version = Assembly.GetExecutingAssembly().GetName().Version?.ToString(),
            os = Environment.OSVersion.VersionString,
            architecture = RuntimeInformation.ProcessArchitecture.ToString(),
            osArchitecture = RuntimeInformation.OSArchitecture.ToString(),
            runtime = Environment.Version.ToString(),
            elevated = IsElevated(),
            interactive = Environment.UserInteractive
        });
    }

    private static bool IsElevated()
    {
        if (!OperatingSystem.IsWindows()) return false;
        using var identity = System.Security.Principal.WindowsIdentity.GetCurrent();
        return new System.Security.Principal.WindowsPrincipal(identity).IsInRole(System.Security.Principal.WindowsBuiltInRole.Administrator);
    }

    public void Write(string eventName, string? sessionId = null, object? fields = null)
    {
        lock (gate)
        {
            if (disposed) return;
            try
            {
                Directory.CreateDirectory(folder);
                if (currentPath.Length == 0 || !File.Exists(currentPath) || new FileInfo(currentPath).Length >= MaxBytes)
                {
                    currentPath = Path.Combine(folder, $"bridge-{DateTime.UtcNow:yyyyMMdd-HHmmss}-{runId[..8]}-{part++}.jsonl");
                    File.WriteAllText(currentPath, "");
                    foreach (var path in new DirectoryInfo(folder).GetFiles("bridge-*.jsonl").OrderByDescending(x => x.LastWriteTimeUtc).Skip(Retention)) path.Delete();
                }
                var item = new { timestamp = DateTimeOffset.UtcNow, runId, sessionId, eventName, fields };
                File.AppendAllText(currentPath, JsonSerializer.Serialize(item) + "\n");
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                HasWriteFailure = true;
            }
        }
    }

    public void Export(string destination, BridgeSettings settings)
    {
        lock (gate)
        {
            using var archive = ZipFile.Open(destination, ZipArchiveMode.Create);
            WriteEntry(archive, "settings-sanitized.json", JsonSerializer.Serialize(AppData.SafeSettings(settings), AppData.Json));
            WriteEntry(archive, "environment.json", JsonSerializer.Serialize(new
            {
                exportedUtc = DateTimeOffset.UtcNow,
                version = Assembly.GetExecutingAssembly().GetName().Version?.ToString(),
                os = Environment.OSVersion.VersionString,
                architecture = RuntimeInformation.ProcessArchitecture.ToString(),
                osArchitecture = RuntimeInformation.OSArchitecture.ToString(),
                runtime = Environment.Version.ToString(), elevated = IsElevated(), loggingFailure = HasWriteFailure,
                limitations = "Local key injection only. No remote paste acknowledgement. No transcript or audio collected."
            }, AppData.Json));
            var manifest = Path.Combine(AppContext.BaseDirectory, "build-info.json");
            if (File.Exists(manifest)) archive.CreateEntryFromFile(manifest, "build-info.json");
            if (Directory.Exists(folder))
                foreach (var path in Directory.GetFiles(folder, "bridge-*.jsonl")) archive.CreateEntryFromFile(path, "logs/" + Path.GetFileName(path));
            WriteEntry(archive, "README.txt", "诊断包含版本、系统、脱敏配置与滚动事件日志。不含识别文字、音频、剪贴板内容、窗口标题或绑定程序路径。\n请另外提供：本机/远端操作系统、豆包及 UU 版本、故障发生时间、期望和实际表现。请勿附敏感听写内容。\n");
        }
    }

    private static void WriteEntry(ZipArchive zip, string path, string text)
    {
        using var writer = new StreamWriter(zip.CreateEntry(path).Open());
        writer.Write(text);
    }
    public void Dispose() { Write("app.stop"); lock (gate) disposed = true; }
}
