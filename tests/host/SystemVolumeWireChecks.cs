using System.Net.WebSockets;
using System.Security.Cryptography;
using System.Text.Json;
using System.Diagnostics;
using Microsoft.AspNetCore.Hosting.Server;
using Microsoft.AspNetCore.Hosting.Server.Features;
using Microsoft.Extensions.DependencyInjection;
using SofaTap;

internal static class SystemVolumeWireChecks
{
    // Production TLS/authentication/framing with fake backends. No native audio,
    // accessibility, application launch, or real keyboard/mouse calls are used.
    internal static async Task Run(Action<bool, string> check)
    {
        foreach (var mode in new[] { "ready", "dry-run", "legacy", "stalled" })
        {
            var directory = Path.Combine(Path.GetTempPath(), "sofatap-volume-wire-" + Guid.NewGuid().ToString("N"));
            try
            {
                using var credentials = Credentials.LoadOrCreate(directory);
                var input = new Input(); using var volume = new Volume { Stalled = mode == "stalled" };
                var server = new ReceiverServer(new(mode == "dry-run", directory, 0), credentials, input,
                    systemVolume: mode == "legacy" ? null : volume);
                await using var app = server.Build();
                using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(30));
                try
                {
                    await app.StartAsync(deadline.Token);
                    var address = app.Services.GetRequiredService<IServer>().Features.Get<IServerAddressesFeature>()!.Addresses.Single();
                    using var socket = new ClientWebSocket();
                    socket.Options.Proxy = null;
                    var fingerprint = SHA256.HashData(credentials.Certificate.RawData);
                    socket.Options.RemoteCertificateValidationCallback = (_, certificate, _, _) => certificate is not null &&
                        CryptographicOperations.FixedTimeEquals(SHA256.HashData(certificate.GetRawCertData()), fingerprint);
                    socket.Options.SetRequestHeader("Authorization", "Bearer " + credentials.Token);
                    await socket.ConnectAsync(new UriBuilder("wss", "127.0.0.1", new Uri(address).Port, "/control").Uri, deadline.Token);
                    var hello = await Read(socket, deadline.Token);
                    if (mode == "stalled")
                    {
                        check(volume.Entered.Wait(TimeSpan.FromSeconds(2)), "fixture audio capability probe is blocked");
                        var watch = Stopwatch.StartNew();
                        await Send(socket, new { id = Guid.NewGuid(), type = "ping" }, deadline.Token);
                        var ping = await Read(socket, deadline.Token);
                        await Send(socket, new { id = Guid.NewGuid(), type = "move", dx = .5, dy = -.5 }, deadline.Token);
                        var move = await Read(socket, deadline.Token);
                        check(watch.Elapsed < TimeSpan.FromSeconds(1) && ping.GetProperty("systemVolume").ValueKind == JsonValueKind.Null &&
                            move.GetProperty("ok").GetBoolean() && input.Actions == 1 && volume.Writes == 0,
                            "stalled optional audio probe never delays real receiver ping or pointer action");
                        volume.Release.Set();
                    }
                    else if (mode != "ready")
                    {
                        check(!hello.TryGetProperty("systemVolume", out _), mode + " hello does not advertise volume");
                        await Send(socket, new { id = Guid.NewGuid(), type = "volume", command = "up" }, deadline.Token);
                        var refused = await Read(socket, deadline.Token);
                        check(!refused.GetProperty("ok").GetBoolean() && volume.Writes == 0 && volume.Probes == 0 && input.Actions == 0,
                            mode + " refuses volume without probing or changing audio");
                        await Send(socket, new { id = Guid.NewGuid(), type = "ping" }, deadline.Token);
                        check((await Read(socket, deadline.Token)).GetProperty("systemVolume").ValueKind == JsonValueKind.Null,
                            mode + " ping explicitly reports null volume capability");
                    }
                    else
                    {
                        var capability = hello.TryGetProperty("systemVolume", out var initial) ? initial
                            : await WaitCapability(socket, true, deadline.Token);
                        check(capability.GetProperty("version").GetInt32() == 1 && volume.Writes == 0,
                            "real TLS hello or subsequent ping advertises support without waiting for audio probe");
                        var action = new { id = Guid.NewGuid().ToString("D"), type = "volume", command = "up" };
                        await Send(socket, action, deadline.Token);
                        var ack = await Read(socket, deadline.Token);
                        await Send(socket, action, deadline.Token);
                        var duplicate = await Read(socket, deadline.Token);
                        check(ack.GetProperty("ok").GetBoolean() && duplicate.GetRawText() == ack.GetRawText() &&
                            volume.Writes == 1 && input.Actions == 0, "real volume ACK and duplicate do not inject or replay input");
                        await Send(socket, new { id = action.id, type = "volume", command = "mute" }, deadline.Token);
                        check(!(await Read(socket, deadline.Token)).GetProperty("ok").GetBoolean() && volume.Writes == 1,
                            "real wire rejects same UUID with different volume operation");
                        await Send(socket, new { id = Guid.NewGuid(), type = "volume", command = "up", amount = 50 }, deadline.Token);
                        check(!(await Read(socket, deadline.Token)).GetProperty("ok").GetBoolean() && volume.Writes == 1,
                            "real wire rejects arbitrary volume arguments");
                        volume.Supported = false;
                        check((await WaitCapability(socket, false, deadline.Token)).ValueKind == JsonValueKind.Null,
                            "ping emits explicit null when default output loses support");
                        volume.Supported = true;
                        check((await WaitCapability(socket, true, deadline.Token)).GetProperty("version").GetInt32() == 1,
                            "ping restores capability when supported output returns");
                        volume.Fail = true;
                        var uncertain = new { id = Guid.NewGuid(), type = "volume", command = "mute" };
                        await Send(socket, uncertain, deadline.Token);
                        var failure = await Read(socket, deadline.Token);
                        volume.Fail = false;
                        await Send(socket, uncertain, deadline.Token);
                        check(!failure.GetProperty("ok").GetBoolean() && (await Read(socket, deadline.Token)).GetRawText() == failure.GetRawText() &&
                            volume.Writes == 2, "wire caches uncertain audio failure after provider recovers");
                        input.Available = false;
                        await Send(socket, new { id = Guid.NewGuid(), type = "ping" }, deadline.Token);
                        check((await Read(socket, deadline.Token)).GetProperty("systemVolume").ValueKind == JsonValueKind.Null,
                            "locked desktop withdraws audio capability");
                        await Send(socket, new { id = Guid.NewGuid(), type = "volume", command = "down" }, deadline.Token);
                        check(!(await Read(socket, deadline.Token)).GetProperty("ok").GetBoolean() && volume.Writes == 2,
                            "locked desktop refuses volume at receiver even for authenticated controller");
                    }
                    await socket.CloseAsync(WebSocketCloseStatus.NormalClosure, "Fixture complete.", deadline.Token);
                }
                finally { await app.StopAsync(CancellationToken.None); }
            }
            finally { Directory.Delete(directory, true); }
        }
    }
    private static Task Send(ClientWebSocket socket, object value, CancellationToken cancellation) =>
        socket.SendAsync(new ArraySegment<byte>(JsonSerializer.SerializeToUtf8Bytes(value)), WebSocketMessageType.Text, true, cancellation);
    private static async Task<JsonElement> WaitCapability(ClientWebSocket socket, bool supported, CancellationToken cancellation)
    {
        var watch = Stopwatch.StartNew();
        while (watch.Elapsed < TimeSpan.FromSeconds(5))
        {
            await Send(socket, new { id = Guid.NewGuid(), type = "ping" }, cancellation);
            var capability = (await Read(socket, cancellation)).GetProperty("systemVolume");
            if ((capability.ValueKind == JsonValueKind.Object) == supported) return capability;
            await Task.Delay(50, cancellation);
        }
        throw new IOException("Audio fixture capability did not refresh.");
    }
    private static async Task<JsonElement> Read(ClientWebSocket socket, CancellationToken cancellation)
    {
        var buffer = new byte[Protocol.MaximumFrameBytes + 1]; var count = 0;
        WebSocketReceiveResult frame;
        do
        {
            frame = await socket.ReceiveAsync(new ArraySegment<byte>(buffer, count, buffer.Length - count), cancellation);
            if (frame.MessageType != WebSocketMessageType.Text) throw new IOException("Expected fixture JSON.");
            count += frame.Count;
            if (count > Protocol.MaximumFrameBytes) throw new IOException("Oversized fixture JSON.");
        } while (!frame.EndOfMessage);
        using var document = JsonDocument.Parse(buffer.AsMemory(0, count));
        return document.RootElement.Clone();
    }
    private sealed class Input : IInputInjector
    {
        public bool Available { get; set; } = true;
        internal int Actions;
        public void Apply(ActionMessage action) => Actions++;
        public void ReleaseAll() { }
    }
    private sealed class Volume : ISystemVolume, IDisposable
    {
        internal volatile bool Supported = true, Fail;
        internal bool Stalled;
        internal readonly ManualResetEventSlim Entered = new(), Release = new(), Finished = new();
        internal int Writes, Probes;
        public bool Available
        {
            get
            {
                Interlocked.Increment(ref Probes);
                if (Stalled) { Entered.Set(); Release.Wait(); Finished.Set(); }
                return Supported;
            }
        }
        public void Apply(string command)
        {
            Writes++;
            if (!Supported || Fail) throw new InputInjectionException("volume_unknown: fixture");
        }
        public void Dispose()
        {
            Release.Set();
            if (Entered.IsSet) Finished.Wait(TimeSpan.FromSeconds(2));
            Entered.Dispose(); Release.Dispose(); Finished.Dispose();
        }
    }
}
