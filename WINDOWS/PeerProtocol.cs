using System.Collections.Concurrent;
using System.Net;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace FTPortal.Windows;

internal sealed record PeerRemoteFile(string Id, string Name, long Size, string Mime);

internal sealed record PeerInfo(
    [property: JsonPropertyName("protocol")] string Protocol,
    string DeviceId,
    string LobbyId,
    string Alias,
    string Platform,
    int PeerPort,
    int LegacyPort,
    bool LobbyActive,
    int FileCount,
    IReadOnlyList<PeerRemoteFile> Files,
    IReadOnlyList<string>? Compatible,
    IReadOnlyList<string>? Capabilities
);

internal sealed record PeerLobby(
    string DeviceId,
    string LobbyId,
    string Alias,
    string Platform,
    string Host,
    int PeerPort,
    int LegacyPort,
    IReadOnlyList<PeerRemoteFile> Files,
    string ProtocolVersion,
    IReadOnlyList<string> Capabilities
)
{
    public bool SupportsOffers =>
        string.Equals(ProtocolVersion, PeerProtocol.VersionV2, StringComparison.Ordinal) &&
        Capabilities.Contains(PeerProtocol.CapOffers, StringComparer.OrdinalIgnoreCase);
}

internal static class PeerIdentity
{
    private static readonly object Gate = new();
    private static string? _deviceId;

    public static string DeviceId()
    {
        lock (Gate)
        {
            if (!string.IsNullOrWhiteSpace(_deviceId)) return _deviceId;

            var directory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "FTPortal");
            Directory.CreateDirectory(directory);
            var path = Path.Combine(directory, "device-id.txt");
            if (File.Exists(path))
            {
                var existing = File.ReadAllText(path).Trim();
                if (existing.Length is >= 16 and <= 64 && existing.All(char.IsLetterOrDigit))
                {
                    _deviceId = existing;
                    return existing;
                }
            }

            _deviceId = Guid.NewGuid().ToString("N");
            File.WriteAllText(path, _deviceId);
            return _deviceId;
        }
    }

    public static string Alias() => string.IsNullOrWhiteSpace(Environment.MachineName) ? "Windows PC" : Environment.MachineName;
}

internal static class PeerProtocol
{
    public const string VersionV1 = "ftportal/1";
    public const string VersionV2 = "ftportal/2";
    public const string Version = VersionV2;
    public const int Port = 47171;

    public const string InfoPathV1 = "/api/ftportal/v1/info";
    public const string DownloadPrefixV1 = "/api/ftportal/v1/download/";
    public const string InfoPathV2 = "/api/ftportal/v2/info";
    public const string OfferPathV2 = "/api/ftportal/v2/offers";
    public const string TransferPrefixV2 = "/api/ftportal/v2/transfers/";

    // Compatibility aliases for the original direct-pull path.
    public const string InfoPath = InfoPathV1;
    public const string DownloadPrefix = DownloadPrefixV1;

    public const string CapOffers = "offers";
    public const string CapAcceptDecline = "accept-decline";
    public const string CapBearerToken = "bearer-token";
    public const string CapVerificationCode = "verification-code";
    public static readonly IReadOnlyList<string> CapabilitiesV2 =
        ["lobbies", CapOffers, CapAcceptDecline, CapBearerToken, CapVerificationCode];

    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web)
    {
        PropertyNameCaseInsensitive = true
    };

    public static PeerInfo CreateInfo(ShareRegistry shares, int legacyPort, string version = VersionV2)
    {
        var files = shares.All()
            .Select(file => new PeerRemoteFile(file.Id, file.Name, file.Size, file.Mime))
            .ToArray();
        var id = PeerIdentity.DeviceId();
        return new PeerInfo(
            version,
            id,
            $"lobby-{id}",
            PeerIdentity.Alias(),
            "Windows",
            Port,
            legacyPort,
            files.Length > 0,
            files.Length,
            files,
            version == VersionV2 ? [VersionV1] : null,
            version == VersionV2 ? CapabilitiesV2 : null
        );
    }

    public static PeerLobby? ParseLobby(string host, string json)
    {
        try
        {
            var info = JsonSerializer.Deserialize<PeerInfo>(json, JsonOptions);
            if (info is null ||
                (info.Protocol != VersionV2 && info.Protocol != VersionV1) ||
                !info.LobbyActive ||
                info.Files.Count == 0 ||
                string.IsNullOrWhiteSpace(info.DeviceId)) return null;

            return new PeerLobby(
                info.DeviceId,
                info.LobbyId,
                string.IsNullOrWhiteSpace(info.Alias) ? host : info.Alias,
                string.IsNullOrWhiteSpace(info.Platform) ? "Unknown" : info.Platform,
                host,
                info.PeerPort is > 0 and <= 65535 ? info.PeerPort : Port,
                info.LegacyPort,
                info.Files,
                info.Protocol,
                info.Capabilities ?? []
            );
        }
        catch (JsonException)
        {
            return null;
        }
    }
}

internal static class PeerDiscovery
{
    private static readonly HttpClient Client = new(new SocketsHttpHandler
    {
        ConnectTimeout = TimeSpan.FromMilliseconds(350),
        UseProxy = false
    })
    {
        Timeout = TimeSpan.FromMilliseconds(900)
    };

    public static async Task<IReadOnlyList<PeerLobby>> DiscoverAsync(
        IEnumerable<IPAddress> localAddresses,
        CancellationToken cancellationToken = default)
    {
        var own = localAddresses
            .Where(address => address.AddressFamily == System.Net.Sockets.AddressFamily.InterNetwork)
            .Select(address => address.ToString())
            .ToHashSet(StringComparer.Ordinal);
        var candidates = new HashSet<string>(StringComparer.Ordinal);

        foreach (var address in own)
        {
            var bytes = IPAddress.Parse(address).GetAddressBytes();
            for (var last = 1; last <= 254; last++)
            {
                var candidate = $"{bytes[0]}.{bytes[1]}.{bytes[2]}.{last}";
                if (!own.Contains(candidate)) candidates.Add(candidate);
            }
        }
        if (candidates.Count == 0) return [];

        var ownId = PeerIdentity.DeviceId();
        var found = new ConcurrentDictionary<string, PeerLobby>(StringComparer.Ordinal);
        var options = new ParallelOptions
        {
            MaxDegreeOfParallelism = 32,
            CancellationToken = cancellationToken
        };

        try
        {
            await Parallel.ForEachAsync(candidates, options, async (host, token) =>
            {
                var lobby = await ProbeAsync(host, token);
                if (lobby is not null && lobby.DeviceId != ownId)
                    found.TryAdd(lobby.DeviceId, lobby);
            });
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            return [];
        }

        return found.Values
            .OrderBy(lobby => lobby.Alias, StringComparer.OrdinalIgnoreCase)
            .ToArray();
    }

    private static async Task<PeerLobby?> ProbeAsync(string host, CancellationToken cancellationToken)
    {
        var v2 = await ProbeVersionAsync(host, PeerProtocol.InfoPathV2, PeerProtocol.VersionV2, cancellationToken);
        if (v2 is not null) return v2;
        return await ProbeVersionAsync(host, PeerProtocol.InfoPathV1, PeerProtocol.VersionV1, cancellationToken);
    }

    private static async Task<PeerLobby?> ProbeVersionAsync(
        string host,
        string path,
        string clientVersion,
        CancellationToken cancellationToken)
    {
        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, $"http://{host}:{PeerProtocol.Port}{path}");
            request.Headers.TryAddWithoutValidation("X-FTPortal-Client", clientVersion);
            request.Headers.Accept.ParseAdd("application/json");
            using var response = await Client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellationToken);
            if (response.StatusCode != HttpStatusCode.OK) return null;
            var json = await response.Content.ReadAsStringAsync(cancellationToken);
            return PeerProtocol.ParseLobby(host, json);
        }
        catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException or OperationCanceledException)
        {
            return null;
        }
    }
}
