using System.Net;
using System.Net.WebSockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Microsoft.AspNetCore.Server.Kestrel.Core;
using QRCoder;

namespace SofaTap;

public sealed record ReceiverOptions(bool DryRun, string DataDirectory, int ControlPort = 53319);

public sealed class ReceiverServer(ReceiverOptions options, Credentials credentials, IInputInjector input, ITextFocusProbe? textFocus = null,
    Func<ILiveTextEditor>? textEditorFactory = null, ISystemVolume? systemVolume = null)
{
    private readonly SemaphoreSlim _controller = new(1, 1);
    private readonly CachedSystemVolume? _volume = options.DryRun || systemVolume is null ? null : new(systemVolume);
    private static readonly JsonSerializerOptions JsonOptions = LiveTextWire.Options;
    private readonly byte[] _token = Encoding.ASCII.GetBytes(credentials.Token);
    private CancellationToken _applicationStopping;
    public WebApplication Build()
    {
        var builder = WebApplication.CreateBuilder(new WebApplicationOptions { Args = [], ContentRootPath = AppContext.BaseDirectory });
        builder.Logging.ClearProviders();
        builder.Logging.SetMinimumLevel(LogLevel.Warning);
        builder.WebHost.ConfigureKestrel(server =>
        {
            server.AddServerHeader = false;
            server.Limits.MaxRequestBodySize = 0;
            server.Limits.RequestHeadersTimeout = TimeSpan.FromSeconds(10);
            server.Limits.KeepAliveTimeout = TimeSpan.FromSeconds(30);
            server.ListenAnyIP(options.ControlPort, listen => { listen.Protocols = HttpProtocols.Http1; listen.UseHttps(credentials.Certificate); });
        });
        var app = builder.Build();
        _applicationStopping = app.Lifetime.ApplicationStopping;
        app.UseWebSockets(new WebSocketOptions { KeepAliveInterval = TimeSpan.FromSeconds(10) });
        app.Run(HandleRequest);
        app.Lifetime.ApplicationStopping.Register(input.ReleaseAll);
        app.Lifetime.ApplicationStopping.Register(() => _volume?.Dispose());
        return app;
    }
    private async Task HandleRequest(HttpContext context)
    {
        context.Response.Headers.CacheControl = "no-store";
        context.Response.Headers["X-Content-Type-Options"] = "nosniff";
        context.Response.Headers["Referrer-Policy"] = "no-referrer";
        if (context.Request.Path != "/control" || context.Request.Method != "GET") { context.Response.StatusCode = 404; return; }
        // Native iOS has no Origin. Reject all browser-originated WebSocket requests, including Origin: null.
        if (context.Request.Headers.ContainsKey("Origin")) { context.Response.StatusCode = 403; return; }
        if (!Authorized(context.Request)) { context.Response.StatusCode = 401; return; }
        if (!context.WebSockets.IsWebSocketRequest) { context.Response.StatusCode = 400; return; }
        if (!await _controller.WaitAsync(0, context.RequestAborted)) { context.Response.StatusCode = 409; return; }
        try
        {
            using var socket = await context.WebSockets.AcceptWebSocketAsync();
            await RunController(socket, context.RequestAborted);
        }
        catch (OperationCanceledException) { }
        catch (WebSocketException) { }
        finally { input.ReleaseAll(); _controller.Release(); }
    }
    private bool Authorized(HttpRequest request)
    {
        if (!request.Headers.TryGetValue("Authorization", out var header) || header.Count != 1) return false;
        var authorization = header[0];
        if (authorization is null || authorization.Length != 7 + _token.Length || !authorization.StartsWith("Bearer ", StringComparison.Ordinal)) return false;
        var candidate = Encoding.ASCII.GetBytes(authorization[7..]);
        return CryptographicOperations.FixedTimeEquals(candidate, _token);
    }
    // The retired account-password pilot must not be discoverable, even when a
    // legacy enrollment file remains on disk. PIN control needs a separate, verified protocol.
    internal static object CreateHello(string name, string platform, bool dryRun,
        string status, TextFocusMetadata focus, bool liveTextSupported = false, bool systemVolumeSupported = false) => new
    {
        type = "hello", version = 1, name, platform, dryRun,
        inputAvailable = status == "ready", inputStatus = status,
        textFocus = ReceiverDistribution.SupportsTextInspection ? focus : new TextFocusMetadata("unknown", 0),
        liveText = ReceiverDistribution.SupportsTextInspection && liveTextSupported && !dryRun ? new { version = 1 } : null,
        systemVolume = systemVolumeSupported && !dryRun && status == "ready" ? new { version = 1 } : null
    };

    private async Task RunController(WebSocket socket, CancellationToken requestAborted)
    {
        using var lifetime = CancellationTokenSource.CreateLinkedTokenSource(requestAborted, _applicationStopping);
        var focusTracker = new TextFocusTracker();
        TextFocusMetadata Focus(string code) => focusTracker.Update(
            ReceiverDistribution.SupportsTextInspection && code == "ready" && !options.DryRun && textFocus is not null
                ? textFocus.Read() : new(TextFocusKind.Unknown), code == "ready" && !options.DryRun);
        var status = ReceiverPlatform.StatusCode(input, options.DryRun);
        using var liveText = ReceiverDistribution.SupportsTextInspection && !options.DryRun && textEditorFactory is not null
            ? new LiveTextSession(textEditorFactory(), () => ReceiverPlatform.StatusCode(input, options.DryRun) == "ready") : null;
        await Send(socket, CreateHello(Environment.MachineName, ReceiverPlatform.Id,
            options.DryRun, status, Focus(status), liveText is not null, VolumeAvailable(status)), lifetime.Token);
        var session = new ActionSession(input, liveText: liveText, systemVolume: _volume);
        var buffer = new byte[Protocol.MaximumFrameBytes + 1];
        while (socket.State == WebSocketState.Open && !lifetime.IsCancellationRequested)
        {
            var offset = 0;
            using var idle = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
            // The whole next message, including its fragments, must arrive within the idle budget.
            idle.CancelAfter(TimeSpan.FromSeconds(20));
            try
            {
                WebSocketReceiveResult received;
                do
                {
                    received = await socket.ReceiveAsync(new ArraySegment<byte>(buffer, offset, buffer.Length - offset), idle.Token);
                    if (received.MessageType == WebSocketMessageType.Close) { await Close(socket, WebSocketCloseStatus.NormalClosure, "Controller closed."); return; }
                    if (received.MessageType != WebSocketMessageType.Text) { await Close(socket, WebSocketCloseStatus.InvalidMessageType, "Text JSON required."); return; }
                    offset += received.Count;
                    if (offset > Protocol.MaximumFrameBytes) { await Close(socket, WebSocketCloseStatus.MessageTooBig, "Frame exceeds 64 KiB."); return; }
                } while (!received.EndOfMessage);
                var bytes = buffer.AsMemory(0, offset);
                ActionAck ack;
                bool isPing = false;
                try
                {
                    var action = Protocol.Parse(bytes);
                    lifetime.Token.ThrowIfCancellationRequested();
                    isPing = action.Type == "ping";
                    ack = session.Execute(action);
                }
                catch (ProtocolException error)
                {
                    ack = ActionAck.Failure(Protocol.TryReadId(bytes), error.Message);
                    await Send(socket, ack, lifetime.Token);
                    if (error.Message.StartsWith("Session action limit", StringComparison.Ordinal)) { await Close(socket, WebSocketCloseStatus.PolicyViolation, "Reconnect required."); return; }
                    continue;
                }
                catch (JsonException) { ack = ActionAck.Failure("", "Malformed JSON."); }
                catch (InvalidOperationException) { ack = ActionAck.Failure(Protocol.TryReadId(bytes), "Invalid JSON string."); }
                if (isPing)
                {
                    var currentStatus = ReceiverPlatform.StatusCode(input, options.DryRun);
                    if (currentStatus != "ready") liveText?.End();
                    await Send(socket, new { ack.Type, ack.Id, ack.Ok, ack.Error,
                        inputAvailable = currentStatus == "ready", inputStatus = currentStatus, dryRun = options.DryRun,
                        textFocus = Focus(currentStatus),
                        // JsonElement null is explicit even with WhenWritingNull: a
                        // removed/unsupported output must revoke a previous capability.
                        systemVolume = JsonSerializer.SerializeToElement(VolumeAvailable(currentStatus) ? new { version = 1 } : null)
                    }, lifetime.Token);
                }
                else await Send(socket, ack, lifetime.Token);
            }
            catch (OperationCanceledException) when (!lifetime.IsCancellationRequested)
            {
                input.ReleaseAll();
                await Close(socket, WebSocketCloseStatus.PolicyViolation, "Controller idle timeout.");
                return;
            }
        }
    }
    private bool VolumeAvailable(string status) => status == "ready" && _volume?.Available == true;
    private static async Task Send(WebSocket socket, object message, CancellationToken cancellation)
    {
        using var bounded = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        bounded.CancelAfter(TimeSpan.FromSeconds(5));
        var bytes = JsonSerializer.SerializeToUtf8Bytes(message, JsonOptions);
        if (bytes.Length > Protocol.MaximumFrameBytes) throw new WebSocketException("Response exceeds the frame limit.");
        await socket.SendAsync(bytes, WebSocketMessageType.Text, true, bounded.Token);
    }
    private static async Task Close(WebSocket socket, WebSocketCloseStatus status, string reason)
    {
        using var bounded = new CancellationTokenSource(TimeSpan.FromSeconds(2));
        try { await socket.CloseOutputAsync(status, reason, bounded.Token); }
        catch (WebSocketException) { }
        catch (OperationCanceledException) { }
    }
    private string PairingUrl(string host) => PairingUri.Create(host, options.ControlPort, credentials.Token,
        credentials.Fingerprint, ReceiverPlatform.Id, Environment.MachineName);
    public void RequestLinuxAccess()
    {
        if (!options.DryRun && input is LinuxInput linux) linux.RequestAccess();
    }
    public object NativeState()
    {
        var pairings = LocalAddresses().Select(address =>
        {
            var uri = PairingUrl(address);
            using var data = QRCodeGenerator.GenerateQrCode(uri, QRCodeGenerator.ECCLevel.Q);
            using var qr = new PngByteQRCode(data);
            return new { host = address, uri, qrPng = Convert.ToBase64String(qr.GetGraphic(5)) };
        }).ToArray();
        return new { type = "state", name = Environment.MachineName, platform = ReceiverPlatform.Id,
            inputStatus = ReceiverPlatform.StatusCode(input, options.DryRun), dryRun = options.DryRun,
            connected = _controller.CurrentCount == 0, pairings,
            // Stable listener/certificate identity is independent of current LAN QR addresses.
            peer = new { port = options.ControlPort, fingerprint = credentials.Fingerprint } };
    }
    private string[] LocalAddresses()
    {
        var certificateAddresses = credentials.CertificateIPv4.ToHashSet(StringComparer.Ordinal);
        var addresses = NetworkAddresses.LocalIPv4().Where(certificateAddresses.Contains).ToArray();
        return addresses;
    }
}
