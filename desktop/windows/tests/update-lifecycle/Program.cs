using System.Diagnostics;
using System.IO.Compression;
using System.Text;
using System.Text.Json;
using SofaTap.Desktop;

// This runner intentionally uses the real Program / copied-executable helper.
// It is forbidden on self-hosted runners or any machine with Sofatap user data.
if (!OperatingSystem.IsWindows() || Environment.GetEnvironmentVariable("GITHUB_ACTIONS") != "true" ||
    Environment.GetEnvironmentVariable("RUNNER_ENVIRONMENT") != "github-hosted")
    throw new InvalidOperationException("Updater lifecycle checks run only on an ephemeral GitHub-hosted Windows runner.");
if (args.Length != 4) throw new ArgumentException("Expected old frontend, new frontend, fixture host, artifact directory.");
var runnerTemp = Path.GetFullPath(Environment.GetEnvironmentVariable("RUNNER_TEMP") ?? throw new IOException("RUNNER_TEMP missing."));
var work = Path.GetFullPath(args[3]);
if (!work.StartsWith(Path.TrimEndingDirectorySeparator(runnerTemp) + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase) || Directory.Exists(work))
    throw new IOException("Artifact directory must be a new child of RUNNER_TEMP.");
UpdatePackage.NoLinks(runnerTemp);
var appData = Path.GetDirectoryName(WindowsUpdates.Root)!;
var startupShortcut = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Startup), "SofaTap.lnk");
if (Directory.Exists(appData) || File.Exists(appData) || File.Exists(startupShortcut) || Process.GetProcessesByName("SofaTap").Length != 0 || Process.GetProcessesByName("SofaTapHost").Length != 0)
    throw new IOException("Existing Sofatap data, startup entry or process found; refusing to borrow this user profile.");
foreach (var path in args.Take(3)) if (!File.Exists(path)) throw new FileNotFoundException("Missing test executable", path);
Directory.CreateDirectory(work);
Directory.CreateDirectory(appData);
var ownership = Guid.NewGuid().ToString("N");
var ownershipFile = Path.Combine(appData, "ci-lifecycle-owner");
File.WriteAllText(ownershipFile, ownership);
var cases = new List<object>();
var checkCount = 0;
void Check(bool condition, string description)
{
    if (!condition) throw new InvalidDataException(description);
    checkCount++;
}
string Hash(string path) => UpdatePackage.HashFile(path);
void CheckOwner()
{
    if (File.ReadAllText(ownershipFile) != ownership) throw new IOException("CI profile ownership changed.");
}
void WriteManifest(string folder, string version)
{
    var files = Directory.EnumerateFiles(folder, "*", SearchOption.AllDirectories)
        .Where(path => Path.GetFileName(path) != UpdatePackage.ManifestName)
        .ToDictionary(path => Path.GetRelativePath(folder, path).Replace('\\', '/'), Hash);
    WindowsUpdates.AtomicJson(Path.Combine(folder, UpdatePackage.ManifestName), new PackageManifest(UpdatePackage.Product, version, "x64", files));
}
void CreateInstallation(string path, string frontend, string version, string mode)
{
    Directory.CreateDirectory(path);
    File.Copy(frontend, Path.Combine(path, "SofaTap.exe"));
    File.Copy(args[2], Path.Combine(path, "SofaTapHost.exe"));
    File.WriteAllText(Path.Combine(path, "fixture-host-mode.txt"), mode);
    File.WriteAllText(Path.Combine(path, "sofatap-ci-owned-install"), ownership);
    WriteManifest(path, version);
}
List<Process> OwnedProcesses()
{
    var owned = new List<Process>();
    foreach (var process in Process.GetProcesses())
    {
        try
        {
            var path = process.MainModule?.FileName;
            if (process.Id != Environment.ProcessId && path is not null &&
                (path.StartsWith(work + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase) ||
                 path.StartsWith(WindowsUpdates.Root + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))) owned.Add(process);
            else process.Dispose();
        }
        catch (Exception error) when (error is InvalidOperationException or System.ComponentModel.Win32Exception) { process.Dispose(); }
    }
    return owned;
}
async Task StopOwnedAsync()
{
    CheckOwner();
    var deadline = DateTime.UtcNow.AddSeconds(20);
    do
    {
        var processes = OwnedProcesses();
        if (processes.Count == 0) return;
        foreach (var process in processes)
        {
            using (process)
            {
                try
                {
                    if (!process.HasExited) process.Kill(entireProcessTree: true);
                    await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(5));
                }
                catch (Exception error) when (error is InvalidOperationException or System.ComponentModel.Win32Exception) { }
            }
        }
        await Task.Delay(100);
    } while (DateTime.UtcNow < deadline);
    throw new TimeoutException("Owned updater fixture processes did not exit.");
}
async Task<JsonElement> WaitForResultAsync(string path)
{
    var deadline = DateTime.UtcNow.AddSeconds(100);
    while (DateTime.UtcNow < deadline)
    {
        if (File.Exists(path))
        {
            using var result = JsonDocument.Parse(File.ReadAllText(path));
            return result.RootElement.Clone();
        }
        await Task.Delay(200);
    }
    throw new TimeoutException("Real updater did not produce a bounded lifecycle result.");
}
try
{
    foreach (var rollback in new[] { false, true })
    {
        CheckOwner();
        var name = rollback ? "rollback" : "install";
        var folder = Path.Combine(work, name);
        var install = Path.Combine(folder, "Sofatap Test 安装");
        var candidate = Path.Combine(folder, "candidate");
        CreateInstallation(install, args[0], "0.8.0-beta.1", "ready");
        CreateInstallation(candidate, args[1], "0.8.1-beta.1", rollback ? "fail" : "ready");
        var custom = Encoding.UTF8.GetBytes("User-created installation note, preserved exactly.\n");
        File.WriteAllBytes(Path.Combine(install, "user-note.txt"), custom);
        var sentinels = new Dictionary<string, byte[]>
        {
            ["desktop-startup.json"] = Encoding.UTF8.GetBytes("{\"enabled\":false}"),
            ["pairing-fixture.json"] = Encoding.UTF8.GetBytes("inert pairing sentinel; no credential"),
            ["tls-fixture.dat"] = Encoding.UTF8.GetBytes("inert TLS sentinel; no private key"),
            ["user-preferences.json"] = Encoding.UTF8.GetBytes("{\"keep\":true}")
        };
        foreach (var item in sentinels) File.WriteAllBytes(Path.Combine(appData, item.Key), item.Value);
        var id = Guid.NewGuid().ToString("N");
        var ticketFolder = Path.Combine(WindowsUpdates.Root, id);
        Directory.CreateDirectory(ticketFolder);
        var archive = Path.Combine(ticketFolder, "package.zip");
        using (var zip = ZipFile.Open(archive, ZipArchiveMode.Create))
            foreach (var path in Directory.EnumerateFiles(candidate, "*", SearchOption.AllDirectories))
                zip.CreateEntryFromFile(path, UpdatePackage.ArchiveRoot + Path.GetRelativePath(candidate, path).Replace('\\', '/'), CompressionLevel.Fastest);
        var release = new UpdateRelease("v0.8.1-beta.1", "0.8.1-beta.1", "https://github.com/chekusu/sofatap/releases/download/v0.8.1-beta.1/" + UpdatePackage.AssetName, Hash(archive), new FileInfo(archive).Length);
        WindowsUpdates.AtomicJson(Path.Combine(ticketFolder, "ticket.json"), new UpdateTicket(id, install, "0.8.0-beta.1", Hash(Path.Combine(install, "SofaTap.exe")), release));
        // Fresh LastAttempt suppresses all production HTTP checks while still
        // exercising automatic application of a prepared, locally verified ZIP.
        WindowsUpdates.SaveSettings(new(Automatic: true, LastAttempt: DateTimeOffset.UtcNow, PendingTicket: id));
        var start = new ProcessStartInfo(Path.Combine(install, "SofaTap.exe")) { UseShellExecute = false, WorkingDirectory = install };
        start.ArgumentList.Add("--startup");
        // Also make accidental HTTP attempts fail locally, never leave the runner.
        start.Environment["HTTP_PROXY"] = "http://127.0.0.1:9";
        start.Environment["HTTPS_PROXY"] = "http://127.0.0.1:9";
        start.Environment["ALL_PROXY"] = "http://127.0.0.1:9";
        start.Environment["NO_PROXY"] = "";
        using var original = Process.Start(start) ?? throw new IOException("Could not start old fixture frontend.");
        var result = await WaitForResultAsync(Path.Combine(ticketFolder, "result.json"));
        Check(result.GetProperty("status").GetString() == (rollback ? "rolled-back" : "installed"), "Unexpected updater outcome: " + result);
        var expectedFrontend = rollback ? args[0] : args[1];
        Check(Hash(Path.Combine(install, "SofaTap.exe")) == Hash(expectedFrontend), "Installed frontend bytes match expected version");
        Check(UpdatePackage.ReadManifest(Path.Combine(install, UpdatePackage.ManifestName)).Version == (rollback ? "0.8.0-beta.1" : "0.8.1-beta.1"), "Installed manifest remains correct");
        Check(File.ReadAllBytes(Path.Combine(install, "user-note.txt")).SequenceEqual(custom), "Custom installation file preserved");
        foreach (var item in sentinels) Check(File.ReadAllBytes(Path.Combine(appData, item.Key)).SequenceEqual(item.Value), "User profile file preserved: " + item.Key);
        Check(!File.Exists(startupShortcut), "Startup opt-out preserved without creating a real shortcut");
        Check(WindowsUpdates.ReadSettings() is { Automatic: true, PendingTicket: null }, "Update preference and consumed ticket preserved");
        var healthy = Path.Combine(ticketFolder, "healthy.json");
        Check(File.Exists(healthy) != rollback, "Only healthy new backend acknowledged");
        var restarted = Path.Combine(install, "fixture-host-started.json");
        var readyDeadline = DateTime.UtcNow.AddSeconds(15);
        while (!File.Exists(restarted) && DateTime.UtcNow < readyDeadline) await Task.Delay(200);
        Check(File.Exists(restarted), "Expected replacement or rollback host actually restarted");
        using (var receipt = JsonDocument.Parse(File.ReadAllText(restarted)))
        using (var host = Process.GetProcessById(receipt.RootElement.GetProperty("process").GetInt32()))
            Check(!host.HasExited && string.Equals(host.MainModule?.FileName, Path.Combine(install, "SofaTapHost.exe"), StringComparison.OrdinalIgnoreCase), "Only the installed owned fixture host is running");
        await original.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(10));
        Check(original.ExitCode == 0, "Original frontend exits after dispatching helper");
        // A missing folder used to surface as DirectoryNotFoundException with no hint of what the updater did
        // (main run 42482354445). Report the updater's own result instead.
        var retained = Path.Combine(folder, (rollback ? ".Sofatap-failed-" : ".Sofatap-backup-") + id, "SofaTap.exe");
        Check(File.Exists(retained), (rollback ? "Failed replacement" : "Old complete installation") + " not retained at " + retained + "; updater result: " + result);
        if (!rollback)
            Check(Hash(retained) == Hash(args[0]), "Old complete installation retained as backup");
        else
            Check(Hash(retained) == Hash(args[1]), "Failed replacement retained without overwriting original");
        cases.Add(new { name, status = result.GetProperty("status").GetString(), frontend = rollback ? "0.8.0-beta.1" : "0.8.1-beta.1", inertBackend = true, profilePreserved = true });
        await StopOwnedAsync();
    }
    WindowsUpdates.AtomicJson(Path.Combine(work, "lifecycle-results.json"), new { passed = true, checks = checkCount, cases, scope = "GitHub-hosted Windows; real updater and inert backend; no device input or pairing" });
    Console.WriteLine($"Passed {checkCount} real Windows updater lifecycle assertions: successful install + failed-new-backend rollback.");
}
finally
{
    await StopOwnedAsync();
    CheckOwner();
    Directory.Delete(appData, recursive: true);
    // Keep owned work/backup/result artifacts for CI inspection; only this fresh
    // fixture profile is removed. Never enumerate or remove other user files.
}
