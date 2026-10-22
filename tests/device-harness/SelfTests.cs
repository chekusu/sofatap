using System.Net;
using System.Net.Sockets;
using System.Net.WebSockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using SofaTap;

namespace SofaTap.DeviceHarness;

internal static class SelfTests
{
    private static int passed;
    private static void Check(bool success, string name)
    {
        if (!success) { Console.Error.WriteLine("FAIL: " + name); throw new InvalidOperationException(); }
        passed++;
    }
    private static string DirectoryPath() => Path.Combine(Path.GetTempPath(), "sofatap-device-harness-" + Guid.NewGuid().ToString("N"));
    private static JsonDocument State(string path) => JsonDocument.Parse(File.ReadAllText(Path.Combine(path, "state.json")));
    private static string Events(string path)
    {
        // Windows readers must share the writer that remains open for the run.
        using var stream = new FileStream(Path.Combine(path, "events.jsonl"), FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
        using var reader = new StreamReader(stream);
        return reader.ReadToEnd();
    }
    public static void Run()
    {
        var path = DirectoryPath();
        PrivateFiles.PrepareDirectory(path);
        try
        {
            using (var record = new RecordingInput(path, liveTextEnabled: true))
            {
                Check(record.Available, "recording input enables phone controls");
                record.Apply(new("1", "move", Dx: 1000, Dy: -1000));
                using (var state = State(path)) Check(state.RootElement.GetProperty("pointer").GetProperty("x").GetDouble() == 799
                    && state.RootElement.GetProperty("pointer").GetProperty("y").GetDouble() == 0, "local pointer clamps to canvas");
                record.Apply(new("2", "button", Button: "left", Down: true));
                record.Apply(new("3", "move", Dx: -30, Dy: 20));
                record.Apply(new("4", "click", Button: "right"));
                record.Apply(new("5", "scroll", Dx: 12, Dy: -40));
                record.ReleaseAll();
                using (var state = State(path)) Check(state.RootElement.GetProperty("buttons").GetArrayLength() == 0
                    && state.RootElement.GetProperty("clicks").GetProperty("right").GetInt32() == 1, "disconnect releases local drag and records click");
                record.Apply(new("6", "text", Text: "Hello 日本語 👋 café\n第二行"));
                using (var state = State(path)) Check(state.RootElement.GetProperty("text").GetString() == "Hello 日本語 👋 café\n第二行", "Unicode and newline unchanged");
                record.Apply(new("7", "key", Key: "a", Modifiers: ["win"]));
                record.Apply(new("8", "text", Text: "👋"));
                record.Apply(new("9", "key", Key: "backspace", Modifiers: []));
                using (var state = State(path)) Check(state.RootElement.GetProperty("text").GetString() == "", "select all replacement and grapheme deletion");
                PrivateFiles.WriteJson(Path.Combine(path, "control.json"), new { focus = "text", revision = 8 });
                Check(record.Focus() == new TextFocusSnapshot(TextFocusKind.Editable, "harness-text-8"), "owned control enables synthetic text focus");
                PrivateFiles.WriteJson(Path.Combine(path, "control.json"), new { focus = "protected", revision = 9 });
                Check(record.Focus().Kind == TextFocusKind.Protected, "protected synthetic field reported");
                PrivateFiles.WriteJson(Path.Combine(path, "control.json"), new { focus = "notfocused", revision = 10 });
                Check(record.Focus().Kind == TextFocusKind.Other, "non-field synthetic state reported");
                PrivateFiles.WriteJson(Path.Combine(path, "control.json"), new { focus = "text", revision = "bad" });
                Check(record.Focus().Kind == TextFocusKind.Other, "malformed focus revision is ignored without disrupting transport");
                var before = Events(path);
                try { record.Apply(new("10", "text", Text: "sofatap://pair?token=private")); throw new InvalidOperationException(); }
                catch (InputInjectionException) { Check(Events(path) == before, "pairing material rejected before event log"); }
                PrivateFiles.WriteJson(Path.Combine(path, "control.json"), new { focus = "text", revision = 11 });
                using (var live = new LiveTextSession(new HarnessLiveTextEditor(record), () => record.Available))
                {
                    var start = live.Begin();
                    Check(start.Text == "" && start.Revision == 0, "live session reads only the synthetic field");
                    var next = live.Sync(start.Session, 1, "A😀中文", 1, 2);
                    Check(next.Text == "A😀中文" && next.SelectionStart == 1 && next.SelectionLength == 2,
                        "live full-field replacement retains UTF-16 emoji selection");
                    try { live.Sync(start.Session, 1, "duplicate", 9, 0); throw new InvalidOperationException(); }
                    catch (InputInjectionException) { Check(record.ReadLive().Text == "A😀中文", "stale live revision never appends or replaces text"); }
                    var fresh = live.Begin();
                    before = Events(path);
                    try { live.Sync(fresh.Session, 1, "sofatap://pair?token=private", 0, 0); throw new InvalidOperationException(); }
                    catch (InputInjectionException) { Check(Events(path) == before, "live edits exclude pairing material before logging"); }
                    PrivateFiles.WriteJson(Path.Combine(path, "control.json"), new { focus = "protected", revision = 12 });
                    try { live.Begin(); throw new InvalidOperationException(); }
                    catch (InputInjectionException) { Check(true, "live read rejects protected synthetic fields"); }
                }
                using (var lines = new StringReader(Events(path)))
                    while (lines.ReadLine() is { } line) using (JsonDocument.Parse(line)) { }
                Check(true, "every event is a complete JSON line");
                if (!OperatingSystem.IsWindows())
                {
                    Check(File.GetUnixFileMode(path) == (UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute), "runtime directory is private");
                    Check(File.GetUnixFileMode(Path.Combine(path, "state.json")) == (UnixFileMode.UserRead | UnixFileMode.UserWrite), "state is private");
                }
                using (var state = State(path)) Check(!state.RootElement.GetProperty("osInjection").GetBoolean(), "recording output explicitly denies OS input evidence");
            }
            try { PrivateFiles.PrepareDirectory(path); throw new InvalidOperationException(); }
            catch (IOException) { Check(true, "refuses reusing or overwriting an existing run"); }
            Console.WriteLine($"PASS {passed} recording checks; no network, GUI or OS input.");
        }
        finally { Directory.Delete(path, true); }
    }

    public static async Task TransportAsync()
    {
        var path = DirectoryPath();
        PrivateFiles.PrepareDirectory(path);
        try
        {
            using var record = new RecordingInput(path);
            using var focus = new HarnessFocus(record);
            using var credentials = Credentials.LoadOrCreate(Path.Combine(path, "profile"));
            using var probe = new TcpListener(IPAddress.Loopback, 0);
            probe.Start(); var port = ((IPEndPoint)probe.LocalEndpoint).Port; probe.Stop();
            var server = new ReceiverServer(new(false, path, port), credentials, record, focus);
            await using var app = server.Build();
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(15));
            await app.StartAsync(timeout.Token);
            try
            {
                using var denied = new ClientWebSocket();
                denied.Options.RemoteCertificateValidationCallback = (_, certificate, _, _) => certificate is not null
                    && Convert.ToHexStringLower(SHA256.HashData(certificate.GetRawCertData())) == credentials.Fingerprint;
                try { await denied.ConnectAsync(new Uri($"wss://127.0.0.1:{port}/control"), timeout.Token); throw new InvalidOperationException(); }
                catch (WebSocketException) { Check(true, "real server refuses unauthenticated WebSocket"); }
                using var socket = new ClientWebSocket();
                socket.Options.RemoteCertificateValidationCallback = (_, certificate, _, _) => certificate is not null
                    && Convert.ToHexStringLower(SHA256.HashData(certificate.GetRawCertData())) == credentials.Fingerprint;
                socket.Options.SetRequestHeader("Authorization", "Bearer " + credentials.Token);
                await socket.ConnectAsync(new Uri($"wss://127.0.0.1:{port}/control"), timeout.Token);
                using (var hello = await Receive(socket, timeout.Token)) Check(hello.RootElement.GetProperty("inputAvailable").GetBoolean()
                    && !hello.RootElement.GetProperty("dryRun").GetBoolean(), "real TLS hello enables device gestures for recording input");
                var id = Guid.NewGuid().ToString("D");
                var body = JsonSerializer.Serialize(new { id, type = "text", text = "Harness 日本語 👋\nfixture" });
                for (var index = 0; index < 2; index++)
                {
                    await socket.SendAsync(Encoding.UTF8.GetBytes(body), WebSocketMessageType.Text, true, timeout.Token);
                    using var ack = await Receive(socket, timeout.Token);
                    Check(ack.RootElement.GetProperty("ok").GetBoolean(), "real protocol acknowledges synthetic text");
                }
                using (var state = State(path)) Check(state.RootElement.GetProperty("actions").GetProperty("text").GetInt32() == 1
                    && state.RootElement.GetProperty("text").GetString() == "Harness 日本語 👋\nfixture", "production dedup records repeated message once");
                PrivateFiles.WriteJson(Path.Combine(path, "control.json"), new { focus = "text", revision = 1 });
                await socket.SendAsync(JsonSerializer.SerializeToUtf8Bytes(new { id = Guid.NewGuid().ToString("D"), type = "ping" }), WebSocketMessageType.Text, true, timeout.Token);
                using (var ack = await Receive(socket, timeout.Token)) Check(ack.RootElement.GetProperty("textFocus").GetProperty("state").GetString() == "editable", "production heartbeat carries synthetic focus");
                await socket.SendAsync(JsonSerializer.SerializeToUtf8Bytes(new { id = Guid.NewGuid().ToString("D"), type = "button", button = "left", down = true }), WebSocketMessageType.Text, true, timeout.Token);
                using (var ack = await Receive(socket, timeout.Token)) Check(ack.RootElement.GetProperty("ok").GetBoolean(), "production drag down recorded");
                await socket.CloseAsync(WebSocketCloseStatus.NormalClosure, "Test complete", timeout.Token);
                await app.StopAsync(timeout.Token);
                using (var state = State(path)) Check(state.RootElement.GetProperty("buttons").GetArrayLength() == 0, "socket close releases recording drag");
                var logs = Events(path) + File.ReadAllText(Path.Combine(path, "state.json"));
                Check(!logs.Contains(credentials.Token) && !logs.Contains(credentials.Fingerprint) && !logs.Contains("sofatap://"), "recording evidence contains no live pairing credentials");
                Console.WriteLine($"PASS {passed} production TLS/recording checks; desktop input remains untested.");
            }
            finally { await app.StopAsync(CancellationToken.None); }
        }
        finally { Directory.Delete(path, true); }
    }

    private static async Task<JsonDocument> Receive(ClientWebSocket socket, CancellationToken token)
    {
        var buffer = new byte[65536];
        var offset = 0;
        while (true)
        {
            var result = await socket.ReceiveAsync(buffer.AsMemory(offset), token);
            if (result.MessageType != WebSocketMessageType.Text) throw new InvalidOperationException();
            offset += result.Count;
            if (result.EndOfMessage) return JsonDocument.Parse(buffer.AsMemory(0, offset));
            if (offset >= buffer.Length) throw new InvalidOperationException();
        }
    }
}
