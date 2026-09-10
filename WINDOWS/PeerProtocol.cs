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
    IReadOnlyList<PeerRemoteFile> Files
);

internal sealed record PeerLobby(
    string DeviceId,
    string LobbyId,
    string Alias,
    string Platform,
    string Host,
    int PeerPort,
    int LegacyPort,
    IReadOnlyList<PeerRemoteFile> Files
);

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
    public const string Version = "ftportal/1";
    public const int Port = 47171;
    public const string InfoPath = "/api/ftportal/v1/info";
    public const string DownloadPrefix = "/api/ftportal/v1/download/";

    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web)
    {
        PropertyNameCaseInsensitive = true
    };

    public static PeerInfo CreateInfo(ShareRegistry shares, int legacyPort)
    {
        var files = shares.All()
            .Select(file => new PeerRemoteFile(file.Id, file.Name, file.Size, file.Mime))
            .ToArray();
        var id = PeerIdentity.DeviceId();
        return new PeerInfo(
            Version,
            id,
            $"lobby-{id}",
            PeerIdentity.Alias(),
            "Windows",
            Port,
            legacyPort,
            files.Length > 0,
            files.Length,
            files
        );
    }

    public static PeerLobby? ParseLobby(string host, string json)
    {
        try
        {
            var info = JsonSerializer.Deserialize<PeerInfo>(json, JsonOptions);
            if (info is null ||
                info.Protocol != Version ||
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
                info.Files
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
        try
        {
            using var request = new HttpRequestMessage(
                HttpMethod.Get,
                $"http://{host}:{PeerProtocol.Port}{PeerProtocol.InfoPath}"
            );
            request.Headers.TryAddWithoutValidation("X-FTPortal-Client", PeerProtocol.Version);
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
