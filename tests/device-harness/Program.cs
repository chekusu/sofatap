using System.Text.Json;
using SofaTap;
using SofaTap.DeviceHarness;

try
{
    if (args.SequenceEqual(["--self-test"])) { SelfTests.Run(); return; }
    if (args.SequenceEqual(["--transport-check"])) { await SelfTests.TransportAsync(); return; }
    if (args.SequenceEqual(["--help"]))
    {
        Console.WriteLine("Sofatap isolated device harness: no OS input.\n--data-dir <new private directory> --port <1024..65535> [--duration-seconds <1..3600>] [--live-text]\n--self-test\n--transport-check\nPrivate pairing.json must never be copied into reports. Only use synthetic test text.");
        return;
    }
    var parsed = new Dictionary<string, string>();
    var liveTextEnabled = false;
    for (var index = 0; index < args.Length; index++)
    {
        if (args[index] == "--live-text")
        {
            if (liveTextEnabled) throw new ArgumentException();
            liveTextEnabled = true;
            continue;
        }
        if (index + 1 >= args.Length || args[index] is not ("--data-dir" or "--port" or "--duration-seconds")
            || !parsed.TryAdd(args[index], args[index + 1])) throw new ArgumentException();
        index++;
    }
    if (!parsed.TryGetValue("--data-dir", out var directory) || !parsed.TryGetValue("--port", out var portText)
        || !int.TryParse(portText, out var port) || port is < 1024 or > 65535) throw new ArgumentException();
    if (!int.TryParse(parsed.GetValueOrDefault("--duration-seconds", "1800"), out var seconds)
        || seconds is < 1 or > 3600) throw new ArgumentException();
    directory = Path.GetFullPath(directory);
    PrivateFiles.PrepareDirectory(directory);
    using var record = new RecordingInput(directory, liveTextEnabled);
    using var focus = new HarnessFocus(record);
    using var credentials = Credentials.LoadOrCreate(Path.Combine(directory, "profile"));
    var receiver = new ReceiverServer(new(false, directory, port), credentials, record, focus,
        liveTextEnabled ? () => new HarnessLiveTextEditor(record) : null);
    await using var app = receiver.Build();
    using var stop = new CancellationTokenSource(TimeSpan.FromSeconds(seconds));
    Console.CancelKeyPress += (_, item) => { item.Cancel = true; stop.Cancel(); };
    await app.StartAsync(stop.Token);
    // This file alone contains the live private URI and QR. Never print it.
    PrivateFiles.WriteJson(Path.Combine(directory, "pairing.json"), receiver.NativeState());
    Console.WriteLine("READY: isolated recording only; no desktop injection. Private pairing file created.");
    try
    {
        using var timer = new PeriodicTimer(TimeSpan.FromMilliseconds(200));
        while (await timer.WaitForNextTickAsync(stop.Token))
        {
            record.RefreshControl();
            if (PrivateFiles.IsRegularFile(Path.Combine(directory, "stop"))) break;
        }
    }
    catch (OperationCanceledException) when (stop.IsCancellationRequested) { }
    finally
    {
        using var bounded = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        await app.StopAsync(bounded.Token);
        record.ReleaseAll();
        File.Delete(Path.Combine(directory, "pairing.json"));
    }
    Console.WriteLine("STOPPED: listener closed; recorded buttons released; private pairing file removed.");
}
catch (Exception)
{
    // Raw exception text can contain filesystem paths, request details or supplied text.
    Console.Error.WriteLine("Harness failed. Check arguments, a fresh private data directory and an unused port. No OS input was sent.");
    Environment.ExitCode = 1;
}
