using System.IO.Compression;
using System.Text.Json;
using DoubaoVoiceBridge.Core;
using DoubaoVoiceBridge.Windows;

var root = Path.Combine(Path.GetTempPath(), "DoubaoVoiceBridge-DiagnosticsTests-" + Guid.NewGuid().ToString("N"));
Directory.CreateDirectory(root);
var cases = new (string Name, Action<string> Test)[]
{
    ("ZIP includes correlated events, environment and sanitized settings without enrolled path", ExportPrivacy),
    ("valid configuration roundtrips through the actual store", SettingsRoundtrip),
    ("invalid syntactically valid settings fall back without modifying original", InvalidSettings),
    ("malformed JSON falls back without modifying original", MalformedJson),
    ("missing configuration produces defaults and clears stale warnings", MissingSettings),
    ("actual rolling logs retain at most eight parseable files", Rotation)
};
var failures = 0;
try
{
    for (var i = 0; i < cases.Length; i++)
    {
        var path = Path.Combine(root, i.ToString());
        Directory.CreateDirectory(path);
        try { cases[i].Test(path); Console.WriteLine($"PASS {cases[i].Name}"); }
        catch (Exception error) { failures++; Console.WriteLine($"FAIL {cases[i].Name}: {error}"); }
    }
}
finally { Directory.Delete(root, recursive: true); }
Console.WriteLine($"{cases.Length - failures}/{cases.Length} passed");
return failures == 0 ? 0 : 1;

static void Check(bool condition, string reason) { if (!condition) throw new InvalidOperationException(reason); }
static string Read(ZipArchiveEntry entry) { using var reader = new StreamReader(entry.Open()); return reader.ReadToEnd(); }
static BridgeSettings Enrolled() => new()
{
    ApprovedExecutablePath = @"C:\Users\private-user\PrivateMachine\UU\UU.exe",
    AutoPaste = true,
    VoiceMode = VoiceMode.Toggle
};
static void ExportPrivacy(string root)
{
    using var log = new DiagnosticLog(root);
    var settings = Enrolled();
    log.Write("test.session", "session-test-0001", new { state = "Listening", lengthBucket = "17-64" });
    var archivePath = Path.Combine(root, "diagnostics.zip");
    log.Export(archivePath, settings);
    using var zip = ZipFile.OpenRead(archivePath);
    var config = zip.GetEntry("settings-sanitized.json") ?? throw new Exception("config missing");
    var environment = zip.GetEntry("environment.json") ?? throw new Exception("environment missing");
    Check(zip.GetEntry("README.txt") is not null, "README missing");
    using var configJson = JsonDocument.Parse(Read(config));
    Check(configJson.RootElement.GetProperty("targetEnrolled").GetBoolean(), "enrollment flag missing");
    Check(configJson.RootElement.GetProperty("AutoPaste").GetBoolean(), "settings value missing");
    Check(!configJson.RootElement.TryGetProperty("ApprovedExecutablePath", out _), "path property exported");
    using var envJson = JsonDocument.Parse(Read(environment));
    Check(envJson.RootElement.GetProperty("architecture").GetString()?.Length > 0, "architecture absent");
    Check(envJson.RootElement.GetProperty("runtime").GetString()?.Length > 0, "runtime absent");
    Check(envJson.RootElement.GetProperty("loggingFailure").ValueKind == JsonValueKind.False, "unexpected logging failure");
    var records = zip.Entries.Where(x => x.FullName.StartsWith("logs/", StringComparison.Ordinal)).SelectMany(x => Read(x).Split('\n', StringSplitOptions.RemoveEmptyEntries)).ToArray();
    Check(records.Length >= 2, "events missing");
    var eventFound = false;
    foreach (var record in records)
    {
        using var json = JsonDocument.Parse(record);
        Check(json.RootElement.GetProperty("runId").GetString()?.Length == 32, "run correlation missing");
        Check(json.RootElement.GetProperty("timestamp").GetString()?.Length > 0, "event timestamp missing");
        if (json.RootElement.GetProperty("eventName").GetString() == "test.session")
        {
            eventFound = true;
            Check(json.RootElement.GetProperty("sessionId").GetString() == "session-test-0001", "session correlation missing");
        }
    }
    Check(eventFound, "session event missing");
    foreach (var entry in zip.Entries)
    {
        var text = Read(entry);
        Check(!text.Contains("PrivateMachine", StringComparison.Ordinal) && !text.Contains("private-user", StringComparison.Ordinal), "enrolled path leaked");
        Check(!text.Contains(root, StringComparison.Ordinal), "temporary data path leaked");
        Check(!entry.FullName.Contains("..", StringComparison.Ordinal) && !Path.IsPathRooted(entry.FullName), "unsafe archive path");
    }
    Check(!log.HasWriteFailure, "log writes failed");
}
static void SettingsRoundtrip(string root)
{
    var path = Path.Combine(root, "settings.json");
    using var log = new DiagnosticLog(root);
    var settings = Enrolled();
    AppData.Save(settings, path);
    var loaded = AppData.Load(log, path);
    Check(loaded.ApprovedExecutablePath == settings.ApprovedExecutablePath, "enrolled path not persisted locally");
    Check(loaded.AutoPaste && loaded.VoiceMode == VoiceMode.Toggle, "settings roundtrip changed values");
    Check(loaded.VoiceModifiers.SequenceEqual(settings.VoiceModifiers), "modifiers changed");
    Check(AppData.LoadWarning is null, "valid settings warned");
    Check(!File.Exists(path + ".tmp"), "temporary settings file not cleaned");
}
static void InvalidSettings(string root)
{
    var path = Path.Combine(root, "settings.json");
    using var log = new DiagnosticLog(root);
    foreach (var json in new[] { "{\"SchemaVersion\":2}", "{\"VoiceModifiers\":null}", "{\"VoiceModifiers\":[164,164]}", "{\"TriggerKey\":13}", "null" })
    {
        File.WriteAllText(path, json);
        var loaded = AppData.Load(log, path);
        Check(loaded.SchemaVersion == 1 && loaded.TriggerKey == 0x77 && loaded.VoiceModifiers is not null, "invalid settings not defaulted");
        Check(!loaded.AutoPaste && loaded.VoiceMode == VoiceMode.Manual && loaded.ApprovedExecutablePath is null, "unsafe fallback");
        Check(AppData.LoadWarning is not null, "invalid settings warning absent");
        Check(File.ReadAllText(path) == json, "invalid original file overwritten");
    }
}
static void MalformedJson(string root)
{
    var path = Path.Combine(root, "settings.json");
    const string json = "{ malformed JSON";
    File.WriteAllText(path, json);
    using var log = new DiagnosticLog(root);
    var settings = AppData.Load(log, path);
    Check(settings.VoiceMode == VoiceMode.Manual && !settings.AutoPaste, "malformed JSON not defaulted");
    Check(AppData.LoadWarning is not null && File.ReadAllText(path) == json, "malformed file modified or warning absent");
}
static void MissingSettings(string root)
{
    var path = Path.Combine(root, "settings.json");
    using var log = new DiagnosticLog(root);
    File.WriteAllText(path, "null");
    AppData.Load(log, path);
    File.Delete(path);
    var settings = AppData.Load(log, path);
    Check(settings.VoiceMode == VoiceMode.Manual && AppData.LoadWarning is null, "missing settings retained stale warning");
    Check(!File.Exists(path), "load created settings unexpectedly");
}
static void Rotation(string root)
{
    using (var log = new DiagnosticLog(root))
    {
        // Deliberately large fixed test metadata exercises the production 2 MiB rotation threshold.
        // This is synthetic padding, never a transcript or clipboard payload.
        var fields = new { syntheticTestPadding = new string('x', 300 * 1024), step = "rotation" };
        for (var i = 0; i < 64; i++) log.Write("test.rotation", "rotation-session", fields);
        Check(!log.HasWriteFailure, "rotation write failed");
        Check(Directory.GetFiles(Path.Combine(root, "logs"), "bridge-*.jsonl").Length == 8, "rotation did not retain eight files");
        log.Export(Path.Combine(root, "rotation.zip"), new BridgeSettings());
    }
    var files = Directory.GetFiles(Path.Combine(root, "logs"), "bridge-*.jsonl");
    Check(files.Length <= 8, "retention exceeded after disposal");
    foreach (var file in files)
    {
        Check(new FileInfo(file).Length < 3 * 1024 * 1024, "log file grew past bounded rotation plus one test record");
        foreach (var line in File.ReadLines(file))
        {
            using var json = JsonDocument.Parse(line);
            Check(json.RootElement.GetProperty("runId").GetString()?.Length == 32, "invalid rotated event");
        }
    }
}
