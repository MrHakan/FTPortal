using System.Collections.Concurrent;
using System.Net;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace FTPortal.Windows;

internal sealed record PeerOfferFile(string Id, string Name, long Size, string Mime);

internal sealed record PeerOfferWire(
    [property: JsonPropertyName("protocol")] string Protocol,
    string OfferId,
    string SenderDeviceId,
    string SenderAlias,
    string SenderPlatform,
    int PeerPort,
    string Token,
    string VerificationCode,
    long ExpiresAt,
    IReadOnlyList<PeerOfferFile> Files
);

internal sealed record IncomingPeerOffer(
    string OfferId,
    string SenderDeviceId,
    string SenderAlias,
    string SenderPlatform,
    string Host,
    int PeerPort,
    string Token,
    string VerificationCode,
    long ExpiresAt,
    IReadOnlyList<PeerOfferFile> Files
);

internal sealed record PeerOfferReceiveResult(IReadOnlyList<string> Completed, IReadOnlyList<string> Failures);

internal sealed class OutgoingPeerGrant(string token, long expiresAt, IEnumerable<string> fileIds)
{
    public string Token { get; } = token;
    public long ExpiresAt { get; } = expiresAt;
    public HashSet<string> FileIds { get; } = new(fileIds, StringComparer.OrdinalIgnoreCase);
}

internal static class PeerOfferStore
{
    private const long OfferTtlMs = 5 * 60 * 1000L;
    private const long MaximumClockWindowMs = 10 * 60 * 1000L;
    private const int MaximumIncomingOffers = 20;
    private const int MaximumFilesPerOffer = 128;
    private static readonly object Gate = new();
    private static readonly Dictionary<string, IncomingPeerOffer> IncomingById = new(StringComparer.OrdinalIgnoreCase);
    private static readonly Dictionary<string, OutgoingPeerGrant> OutgoingById = new(StringComparer.OrdinalIgnoreCase);
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web)
    {
        PropertyNameCaseInsensitive = true
    };

    public static PeerOfferWire PrepareOutgoing(IReadOnlyList<SharedFile> files)
    {
        if (files.Count == 0) throw new InvalidOperationException("No pending files to offer.");
        if (files.Count > MaximumFilesPerOffer) throw new InvalidOperationException("Too many files in one offer.");
        if (files.Any(file => file.Size < 0)) throw new InvalidOperationException("All v2 offer files must have a known size.");

        var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        var offerId = Convert.ToHexString(RandomNumberGenerator.GetBytes(16)).ToLowerInvariant();
        var token = Convert.ToHexString(RandomNumberGenerator.GetBytes(32)).ToLowerInvariant();
        var code = RandomNumberGenerator.GetInt32(0, 1_000_000).ToString("D6");
        var expiresAt = now + OfferTtlMs;
        var manifest = files.Select(file => new PeerOfferFile(file.Id, file.Name, file.Size, file.Mime)).ToArray();
        var wire = new PeerOfferWire(
            PeerProtocol.VersionV2,
            offerId,
            PeerIdentity.DeviceId(),
            PeerIdentity.Alias(),
            "Windows",
            PeerProtocol.Port,
            token,
            code,
            expiresAt,
            manifest
        );

        lock (Gate)
        {
            CleanupLocked(now);
            OutgoingById[offerId] = new OutgoingPeerGrant(token, expiresAt, manifest.Select(file => file.Id));
        }
        return wire;
    }

    public static void CancelOutgoing(string offerId)
    {
        lock (Gate) OutgoingById.Remove(offerId);
    }

    public static IncomingPeerOffer? ReceiveIncoming(string remoteHost, string json)
    {
        PeerOfferWire? wire;
        try { wire = JsonSerializer.Deserialize<PeerOfferWire>(json, JsonOptions); }
        catch (JsonException) { return null; }
        if (wire is null) return null;

        var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        if (!string.Equals(wire.Protocol, PeerProtocol.VersionV2, StringComparison.Ordinal) ||
            wire.Files is null ||
            string.IsNullOrWhiteSpace(wire.Token) ||
            string.IsNullOrWhiteSpace(wire.OfferId) ||
            string.IsNullOrWhiteSpace(wire.VerificationCode)) return null;
        if (!IsHex(wire.OfferId, 32) || !IsHex(wire.Token, 64)) return null;
        if (string.IsNullOrWhiteSpace(wire.SenderDeviceId) || string.Equals(wire.SenderDeviceId, PeerIdentity.DeviceId(), StringComparison.OrdinalIgnoreCase)) return null;
        if (wire.VerificationCode.Length != 6 || !wire.VerificationCode.All(char.IsDigit)) return null;
        if (wire.ExpiresAt <= now || wire.ExpiresAt > now + MaximumClockWindowMs) return null;
        if (wire.PeerPort is < 1 or > 65535 || string.IsNullOrWhiteSpace(remoteHost)) return null;
        if (wire.Files.Count is < 1 or > MaximumFilesPerOffer) return null;

        var files = wire.Files
            .Where(file => file is not null && !string.IsNullOrWhiteSpace(file.Id) && file.Id.Length <= 64 && file.Id.All(char.IsLetterOrDigit) && file.Size >= 0)
            .Where(file => !string.IsNullOrWhiteSpace(file.Name) && file.Name.Length <= 255)
            .Select(file => file with
            {
                Name = file.Name,
                Mime = string.IsNullOrWhiteSpace(file.Mime) ? "application/octet-stream" : file.Mime[..Math.Min(file.Mime.Length, 128)]
            })
            .ToArray();
        if (files.Length != wire.Files.Count || files.Select(file => file.Id).Distinct(StringComparer.OrdinalIgnoreCase).Count() != files.Length) return null;

        var alias = string.IsNullOrWhiteSpace(wire.SenderAlias) ? remoteHost : wire.SenderAlias[..Math.Min(wire.SenderAlias.Length, 120)];
        var platform = string.IsNullOrWhiteSpace(wire.SenderPlatform) ? "Unknown" : wire.SenderPlatform[..Math.Min(wire.SenderPlatform.Length, 40)];
        var offer = new IncomingPeerOffer(
            wire.OfferId.ToLowerInvariant(),
            wire.SenderDeviceId,
            alias,
            platform,
            remoteHost,
            wire.PeerPort,
            wire.Token.ToLowerInvariant(),
            wire.VerificationCode,
            wire.ExpiresAt,
            files
        );

        lock (Gate)
        {
            CleanupLocked(now);
            if (!IncomingById.ContainsKey(offer.OfferId) && IncomingById.Count >= MaximumIncomingOffers) return null;
            IncomingById[offer.OfferId] = offer;
        }
        return offer;
    }

    public static IReadOnlyList<IncomingPeerOffer> Incoming()
    {
        lock (Gate)
        {
            CleanupLocked(DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
            return IncomingById.Values.OrderBy(offer => offer.SenderAlias, StringComparer.OrdinalIgnoreCase).ToArray();
        }
    }

    public static void Decline(string offerId)
    {
        lock (Gate) IncomingById.Remove(offerId);
    }

    public static void MarkIncomingFileComplete(string offerId, string fileId)
    {
        lock (Gate)
        {
            if (!IncomingById.TryGetValue(offerId, out var offer)) return;
            var remaining = offer.Files.Where(file => !string.Equals(file.Id, fileId, StringComparison.OrdinalIgnoreCase)).ToArray();
            if (remaining.Length == 0) IncomingById.Remove(offerId);
            else IncomingById[offerId] = offer with { Files = remaining };
        }
    }

    public static bool AuthorizeOutgoing(string offerId, string fileId, string? authorization)
    {
        OutgoingPeerGrant? grant;
        lock (Gate)
        {
            CleanupLocked(DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
            if (!OutgoingById.TryGetValue(offerId, out grant) || !grant.FileIds.Contains(fileId)) return false;
        }
        if (string.IsNullOrWhiteSpace(authorization) || !authorization.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase)) return false;
        var supplied = authorization[7..].Trim().ToLowerInvariant();
        var expectedBytes = Encoding.ASCII.GetBytes(grant.Token);
        var suppliedBytes = Encoding.ASCII.GetBytes(supplied);
        return expectedBytes.Length == suppliedBytes.Length && CryptographicOperations.FixedTimeEquals(expectedBytes, suppliedBytes);
    }

    public static void CompleteOutgoingFile(string offerId, string fileId)
    {
        lock (Gate)
        {
            if (!OutgoingById.TryGetValue(offerId, out var grant)) return;
            grant.FileIds.Remove(fileId);
            if (grant.FileIds.Count == 0) OutgoingById.Remove(offerId);
        }
    }

    private static void CleanupLocked(long now)
    {
        foreach (var id in IncomingById.Where(pair => pair.Value.ExpiresAt <= now).Select(pair => pair.Key).ToArray())
            IncomingById.Remove(id);
        foreach (var id in OutgoingById.Where(pair => pair.Value.ExpiresAt <= now || pair.Value.FileIds.Count == 0).Select(pair => pair.Key).ToArray())
            OutgoingById.Remove(id);
    }

    private static bool IsHex(string value, int length) =>
        value.Length == length && value.All(Uri.IsHexDigit);
}

internal static class PeerOfferClient
{
    private static readonly HttpClient Client = new(new SocketsHttpHandler
    {
        ConnectTimeout = TimeSpan.FromSeconds(3),
        UseProxy = false
    })
    {
        Timeout = TimeSpan.FromSeconds(5)
    };

    public static async Task<PeerOfferWire> SendAsync(PeerLobby lobby, IReadOnlyList<SharedFile> files, CancellationToken cancellationToken = default)
    {
        if (!lobby.SupportsOffers) throw new InvalidOperationException("This lobby only supports the v1 pull flow.");
        var wire = PeerOfferStore.PrepareOutgoing(files);
        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Post, $"http://{lobby.Host}:{lobby.PeerPort}{PeerProtocol.OfferPathV2}");
            request.Headers.TryAddWithoutValidation("X-FTPortal-Client", PeerProtocol.VersionV2);
            request.Headers.Accept.ParseAdd("application/json");
            request.Content = new StringContent(JsonSerializer.Serialize(wire, new JsonSerializerOptions(JsonSerializerDefaults.Web)), Encoding.UTF8, "application/json");
            using var response = await Client.SendAsync(request, cancellationToken);
            if (!response.IsSuccessStatusCode)
                throw new IOException($"Peer rejected offer with HTTP {(int)response.StatusCode} {response.ReasonPhrase}");
            return wire;
        }
        catch
        {
            PeerOfferStore.CancelOutgoing(wire.OfferId);
            throw;
        }
    }
}

internal static class PeerOfferReceiver
{
    private static readonly HttpClient Client = new(new SocketsHttpHandler { UseProxy = false })
    {
        Timeout = Timeout.InfiniteTimeSpan
    };

    public static async Task<PeerOfferReceiveResult> ReceiveAllAsync(
        IncomingPeerOffer offer,
        string destinationDirectory,
        TransferCenter transfers,
        CancellationToken cancellationToken = default)
    {
        var completed = new List<string>();
        var failures = new List<string>();

        try
        {
            Directory.CreateDirectory(destinationDirectory);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
        {
            failures.Add($"Destination unavailable: {TransferError(ex)}");
            return new PeerOfferReceiveResult(completed, failures);
        }

        foreach (var file in offer.Files)
        {
            var target = UniquePath(destinationDirectory, SafeFileName(file.Name));
            var temp = target + $".ftportal-{Guid.NewGuid():N}.part";
            var transferId = transfers.Begin(
                TransferDirection.Receive,
                file.Name,
                $"{offer.SenderAlias} ({offer.Host})",
                file.Size
            );
            using var transferCancellation = CancellationTokenSource.CreateLinkedTokenSource(
                cancellationToken,
                transfers.Token(transferId)
            );
            var transferToken = transferCancellation.Token;
            var received = 0L;
            try
            {
                using var request = new HttpRequestMessage(
                    HttpMethod.Get,
                    $"http://{offer.Host}:{offer.PeerPort}{PeerProtocol.TransferPrefixV2}{offer.OfferId}/{file.Id}"
                );
                request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", offer.Token);
                request.Headers.TryAddWithoutValidation("X-FTPortal-Client", PeerProtocol.VersionV2);
                using var response = await Client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, transferToken);
                if (response.StatusCode != HttpStatusCode.OK)
                    throw new IOException($"{file.Name}: peer returned HTTP {(int)response.StatusCode} {response.ReasonPhrase}");

                await using (var source = await response.Content.ReadAsStreamAsync(transferToken))
                await using (var destination = new FileStream(temp, FileMode.CreateNew, FileAccess.Write, FileShare.None, 128 * 1024, useAsync: true))
                {
                    var buffer = new byte[128 * 1024];
                    while (true)
                    {
                        var read = await source.ReadAsync(buffer.AsMemory(0, buffer.Length), transferToken);
                        if (read == 0) break;
                        await destination.WriteAsync(buffer.AsMemory(0, read), transferToken);
                        received += read;
                        transfers.Update(transferId, received);
                    }
                    await destination.FlushAsync(transferToken);
                }

                transferToken.ThrowIfCancellationRequested();

                if (file.Size >= 0 && received != file.Size)
                    throw new IOException($"{file.Name}: expected {file.Size:N0} bytes, received {received:N0}");

                File.Move(temp, target);
                completed.Add(target);
                PeerOfferStore.MarkIncomingFileComplete(offer.OfferId, file.Id);
                transfers.Finish(transferId, success: true, finalBytes: received);
            }
            catch (Exception ex) when (ex is IOException or HttpRequestException or UnauthorizedAccessException or ArgumentException or NotSupportedException or OperationCanceledException)
            {
                try { if (File.Exists(temp)) File.Delete(temp); } catch { }
                transfers.Finish(transferId, success: false, detail: TransferError(ex), finalBytes: received);
                failures.Add($"{file.Name}: {TransferError(ex)}");
                if (transferToken.IsCancellationRequested || cancellationToken.IsCancellationRequested) break;
            }
        }

        return new PeerOfferReceiveResult(completed, failures);
    }

    public static Task<PeerOfferReceiveResult> ReceiveAllAsync(
        IncomingPeerOffer offer,
        string destinationDirectory,
        CancellationToken cancellationToken = default) =>
        ReceiveAllAsync(offer, destinationDirectory, new TransferCenter(), cancellationToken);

    private static string TransferError(Exception error) => error switch
    {
        OperationCanceledException => "Transfer cancelled",
        HttpRequestException => "Peer connection failed",
        UnauthorizedAccessException => "Destination access denied",
        FileNotFoundException or DirectoryNotFoundException => "Destination unavailable",
        IOException => "Transfer I/O error",
        _ => "Transfer failed"
    };

    private static string SafeFileName(string name)
    {
        var leaf = Path.GetFileName(name);
        if (string.IsNullOrWhiteSpace(leaf)) leaf = "FTPortal-download";
        foreach (var invalid in Path.GetInvalidFileNameChars()) leaf = leaf.Replace(invalid, '_');
        return leaf;
    }

    private static string UniquePath(string directory, string fileName)
    {
        var candidate = Path.Combine(directory, fileName);
        if (!File.Exists(candidate)) return candidate;
        var stem = Path.GetFileNameWithoutExtension(fileName);
        var extension = Path.GetExtension(fileName);
        for (var index = 2; ; index++)
        {
            candidate = Path.Combine(directory, $"{stem} ({index}){extension}");
            if (!File.Exists(candidate)) return candidate;
        }
    }
}
