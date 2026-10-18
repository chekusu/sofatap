using SofaTap;

if (args.Contains("--help", StringComparer.Ordinal))
{
    Console.WriteLine("Sofatap receiver backend\nLaunch the native Sofatap desktop app to pair.\n  --native-ui          Private stdin/stdout bridge for the native desktop app\n  --dry-run            Validate transport without injecting input\n  --data-dir <path>    Store pairing credentials in a separate profile\n  --port <n>           TLS control endpoint (default 53319)");
    return;
}
try
{
    string? Value(string flag)
    {
        var index = Array.IndexOf(args, flag);
        if (index < 0) return null;
        if (index + 1 >= args.Length || args[index + 1].StartsWith("--", StringComparison.Ordinal)) throw new ArgumentException($"Missing value for {flag}.");
        return args[index + 1];
    }
    int Port(string flag, int fallback)
    {
        var value = Value(flag);
        if (value is null) return fallback;
        if (!int.TryParse(value, out var port) || port is < 1 or > 65535) throw new ArgumentException($"Invalid port for {flag}.");
        return port;
    }
    var nativeUi = args.Contains("--native-ui", StringComparer.Ordinal);
    if (!nativeUi || !Console.IsInputRedirected || !Console.IsOutputRedirected)
        throw new InvalidOperationException("Open the native Sofatap desktop app. The backend requires its private input/output pipes.");
    var dryRun = args.Contains("--dry-run", StringComparer.Ordinal);
    if (!OperatingSystem.IsWindows() && !OperatingSystem.IsMacOS() && !OperatingSystem.IsLinux() && !dryRun)
        throw new InvalidOperationException("Sofatap requires Windows, macOS or a supported Linux desktop.");
    var options = new ReceiverOptions(dryRun, ReceiverDistribution.DataDirectory(Value("--data-dir")),
        Port("--port", Port("--control-port", 53319)));
    using var credentials = Credentials.LoadOrCreate(Path.GetFullPath(options.DataDirectory));
    IInputInjector input = dryRun ? new DryRunInput() : OperatingSystem.IsMacOS() ? new MacInput()
        : OperatingSystem.IsLinux() ? new LinuxInput() : new WindowsInput();
    using var inputLifetime = input as IDisposable;
    using var textFocus = ReceiverDistribution.CreateTextFocus(dryRun);
    var textEditorFactory = ReceiverDistribution.CreateTextEditorFactory(dryRun);
    var server = new ReceiverServer(options, credentials, input, textFocus, textEditorFactory, SystemVolume.Create(dryRun));
    await using var app = server.Build();
    try { await NativeDesktopBridge.RunAsync(app, server, dryRun); }
    finally { input.ReleaseAll(); }
}
catch (Exception error) when (error is ArgumentException or InvalidOperationException or IOException or FormatException or System.Text.Json.JsonException or System.Security.Cryptography.CryptographicException)
{
    // Never dump request bodies, pairing tokens, certificate bytes, or raw framework exceptions.
    Console.Error.WriteLine(error is ArgumentException or InvalidOperationException ? error.Message : "Sofatap could not read its local profile or open its ports. Check file permissions and whether another receiver is running.");
    Environment.ExitCode = 1;
}
