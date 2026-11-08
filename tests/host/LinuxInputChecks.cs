using System.Diagnostics;
using System.Text;
using System.Text.Json;
using SofaTap;

internal static class LinuxInputChecks
{
    internal static void Run(Action<bool, string> check)
    {
        var id = Guid.NewGuid().ToString("D");
        var valid = JsonSerializer.Serialize(new { id, ok = true, status = "ready" });
        check(LinuxInput.ParseReply(valid, id).Ok, "Linux worker reply accepted");
        foreach (var invalid in new[] { "[]", "{}", valid.Replace("ready", "future"), valid.Replace(id, Guid.NewGuid().ToString("D")),
            valid.Replace("true", "1"), valid.Replace("\"ok\":true", "\"ok\":true,\"ok\":false"), valid.TrimEnd('}') + ",\"extra\":1}",
            valid.TrimEnd('}') + ",\"error\":\"invalid\"}", valid.Replace("true", "false"), new string('x', 4097) })
        {
            try { LinuxInput.ParseReply(invalid, id); throw new Exception("Malformed worker response accepted"); }
            catch (Exception e) when (e is IOException or JsonException) { check(true, "Linux reply fails closed"); }
        }
        foreach (var action in new[] { new ActionMessage(id, "move", .5, -1), new ActionMessage(id, "scroll", 0, 120),
            new ActionMessage(id, "click", Button: "left"), new ActionMessage(id, "button", Button: "right", Down: true),
            new ActionMessage(id, "key", Key: "a", Modifiers: ["ctrl"]), new ActionMessage(id, "text", Text: "中文\n👋") })
        {
            var parsed = Protocol.Parse(Encoding.UTF8.GetBytes(JsonSerializer.Serialize(LinuxInput.SerializeAction(action))));
            check(parsed.Type == action.Type && parsed.Text == action.Text, "Linux worker receives exact validated action fields");
        }
        // Hosted Windows runners start Python and append files slowly (first launch is scanned), so a fixed
        // 1.2 s status deadline failed there on one run and passed on the next with the same code. Warm Python
        // once and give Windows a longer deadline; the 6 s lifecycle bounds below still hold.
        var deadline = TimeSpan.FromMilliseconds(OperatingSystem.IsWindows() ? 3000 : 1200);
        WarmPython();
        var root = Path.Combine(Path.GetTempPath(), "sofatap-worker-tests-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            foreach (var mode in new[] { "success", "partial", "secret", "wrong_id", "not_ready", "oversized", "eof", "blocked" })
            {
                var audit = Path.Combine(root, mode + ".txt");
                var start = new ProcessStartInfo(OperatingSystem.IsWindows() ? "python" : "python3");
                start.ArgumentList.Add(Path.Combine(AppContext.BaseDirectory, "fake_linux_worker.py"));
                start.ArgumentList.Add(mode); start.ArgumentList.Add(audit);
                using var input = new LinuxInput(start, deadline);
                check(input.Available, "fake Linux worker handshake " + mode);
                var session = new ActionSession(input);
                var action = new ActionMessage(id, "text", Text: "safe-test-text");
                var watch = Stopwatch.StartNew();
                var ack = session.Execute(action);
                check(ack.Ok == (mode == "success"), "Linux action outcome " + mode);
                check(!ack.Error?.Contains("private-text") ?? true, "worker diagnostics never echo input");
                if (mode == "secret") check(ack.Error!.StartsWith("input_unknown:"), "unknown worker failure cannot be treated as a safe text retry");
                check(session.Execute(action) == ack, "unknown/partial Linux action is not replayed");
                input.Dispose();
                check(watch.Elapsed < TimeSpan.FromSeconds(6), "Linux process lifecycle bounded " + mode);
                var lines = File.ReadAllLines(audit);
                check(lines.Count(x => x == "apply") == 1, "Linux worker sees at most one attempted text");
                var pid = int.Parse(lines[0][4..]);
                try { using var process = Process.GetProcessById(pid); check(process.HasExited, "Linux owned worker exits " + mode); }
                catch (ArgumentException) { check(true, "Linux owned worker reaped " + mode); }
                if (mode == "success") check(lines.Contains("quit"), "Linux graceful quit sent");
            }
            foreach (var mode in new[] { "blocked_write", "closed_input" })
            {
                var audit = Path.Combine(root, mode + ".txt");
                var start = new ProcessStartInfo(OperatingSystem.IsWindows() ? "python" : "python3");
                start.ArgumentList.Add(Path.Combine(AppContext.BaseDirectory, "fake_linux_worker.py"));
                start.ArgumentList.Add(mode); start.ArgumentList.Add(audit);
                using var input = new LinuxInput(start, deadline);
                var watch = Stopwatch.StartNew();
                // Force backpressure beyond ordinary pipe capacity without a
                // real desktop. Never log or replay this synthetic payload.
                var action = new ActionMessage(id, "text", Text: new string('\u0001', 16000));
                var ack = new ActionSession(input).Execute(action);
                check(!ack.Ok && ack.Error!.StartsWith("input_unknown"), "Linux stopped stdin is unknown " + mode);
                input.Dispose();
                check(watch.Elapsed < TimeSpan.FromSeconds(6), "Linux blocked writer cannot hang shutdown " + mode);
                var pid = int.Parse(File.ReadLines(audit).First()[4..]);
                try { using var process = Process.GetProcessById(pid); check(process.HasExited, "Linux failed writer worker exits " + mode); }
                catch (ArgumentException) { check(true, "Linux failed writer worker reaped " + mode); }
            }
        }
        finally { Directory.Delete(root, true); }
    }

    private static void WarmPython()
    {
        var start = new ProcessStartInfo(OperatingSystem.IsWindows() ? "python" : "python3") { UseShellExecute = false, CreateNoWindow = true };
        foreach (var argument in new[] { "-c", "import json, os, sys, time" }) start.ArgumentList.Add(argument);
        try { using var warm = Process.Start(start); warm?.WaitForExit(30_000); }
        catch (System.ComponentModel.Win32Exception) { }
    }
}
