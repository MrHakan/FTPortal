using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using System.Buffers;
using System.Net.Sockets;
using System.Text;
using System.Text.Encodings.Web;

namespace FTPortal.Windows;

internal sealed class PortalServer : IAsyncDisposable
{
    private const int MaximumOfferBytes = 128 * 1024;
    private readonly ShareRegistry _shares;
    private readonly TransferCenter _transfers;
    private readonly NetworkTransportManager _network;
    private WebApplication? _legacyApp;
    private WebApplication? _peerApp;

    public int Port { get; private set; }
    public bool PeerAvailable => _peerApp is not null;
    public string? PeerError { get; private set; }

    public PortalServer(ShareRegistry shares, TransferCenter transfers, NetworkTransportManager network)
    {
        _shares = shares;
        _transfers = transfers;
        _network = network;
    }

    public async Task<int> StartAsync(params int[] ports)
    {
        if (_legacyApp is not null) return Port;

        Exception? last = null;
        foreach (var port in ports.Distinct().Where(port => port is > 0 and <= 65535))
        {
            WebApplication? candidate = null;
            try
            {
                candidate = BuildApp(port, legacySurface: true);
                await candidate.StartAsync();
                _legacyApp = candidate;
                Port = port;
                break;
            }
            catch (Exception ex) when (IsPortBindFailure(ex))
            {
                last = ex;
                if (candidate is not null) await candidate.DisposeAsync();
            }
        }

        if (_legacyApp is null)
            throw new IOException("No FTPortal legacy web port could be opened.", last);

        await TryStartPeerAsync();
        return Port;
    }

    private async Task TryStartPeerAsync()
    {
        if (_peerApp is not null) return;
        WebApplication? candidate = null;
        try
        {
            candidate = BuildApp(PeerProtocol.Port, legacySurface: false);
            await candidate.StartAsync();
            _peerApp = candidate;
            PeerError = null;
        }
        catch (Exception ex)
        {
            if (candidate is not null) await candidate.DisposeAsync();
            _peerApp = null;
            PeerError = ShortError(ex);
        }
    }

    private WebApplication BuildApp(int port, bool legacySurface)
    {
        var builder = WebApplication.CreateBuilder(new WebApplicationOptions { Args = Array.Empty<string>() });
        builder.WebHost.ConfigureKestrel(options => options.ListenAnyIP(port));
        var app = builder.Build();
        Configure(app, legacySurface);
        return app;
    }

    private void Configure(WebApplication app, bool legacySurface)
    {
        app.Use(async (context, next) =>
        {
            context.Response.Headers["Cache-Control"] = "no-store";
            context.Response.Headers["X-Content-Type-Options"] = "nosniff";
            context.Response.Headers["Referrer-Policy"] = "no-referrer";
            context.Response.Headers["X-Frame-Options"] = "DENY";
            context.Response.Headers["Content-Security-Policy"] = "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'";

            if (!_network.IsAllowedClient(context.Connection.RemoteIpAddress))
            {
                context.Response.StatusCode = StatusCodes.Status403Forbidden;
                await context.Response.WriteAsync("Client is outside the active local network.", context.RequestAborted);
                return;
            }

            await next();
        });

        app.MapGet(PeerProtocol.InfoPathV1, () => Results.Json(PeerProtocol.CreateInfo(_shares, Port, PeerProtocol.VersionV1)));
        app.MapGet(PeerProtocol.InfoPathV2, () => Results.Json(PeerProtocol.CreateInfo(_shares, Port, PeerProtocol.VersionV2)));
        app.MapPost(PeerProtocol.OfferPathV2, ReceiveOfferAsync);
        app.MapGet(PeerProtocol.TransferPrefixV2 + "{offerId}/{id}", async (HttpContext context, string offerId, string id) =>
        {
            var authorization = context.Request.Headers["Authorization"].ToString();
            if (!PeerOfferStore.AuthorizeOutgoing(offerId, id, authorization))
            {
                context.Response.StatusCode = StatusCodes.Status401Unauthorized;
                context.Response.Headers["WWW-Authenticate"] = "Bearer";
                await context.Response.WriteAsync("Offer authorization failed", context.RequestAborted);
                return;
            }
            await SendOneShotAsync(
                context,
                id,
                protocolVersion: PeerProtocol.VersionV2,
                onCompleted: () => PeerOfferStore.CompleteOutgoingFile(offerId, id)
            );
        });
        app.MapGet(PeerProtocol.DownloadPrefixV1 + "{id}", async (HttpContext context, string id) =>
            await SendOneShotAsync(context, id, protocolVersion: PeerProtocol.VersionV1));

        if (!legacySurface) return;

        app.MapGet("/", () => Results.Content(Html(), "text/html; charset=utf-8"));
        app.MapGet("/api/state", () => Results.Json(new
        {
            files = _shares.All().Select(file => new { file.Id, file.Name, file.Size, file.Mime }),
            transfers = new
            {
                active = _transfers.Active().Select(transfer => new
                {
                    transfer.Id,
                    transfer.Direction,
                    transfer.FileName,
                    transfer.Peer,
                    transfer.BytesTransferred,
                    transfer.TotalBytes,
                    transfer.ProgressPercent,
                    transfer.BytesPerSecond,
                    transfer.EtaSeconds,
                    transfer.StartedAt
                }),
                historyCount = _transfers.History().Count
            }
        }));
        app.MapMethods("/download/{id}", [HttpMethods.Get, HttpMethods.Head], async (HttpContext context, string id) =>
        {
            if (HttpMethods.IsHead(context.Request.Method))
            {
                await SendHeadAsync(context, id);
                return;
            }
            await SendOneShotAsync(context, id, protocolVersion: null);
        });
    }

    private async Task ReceiveOfferAsync(HttpContext context)
    {
        if (context.Request.ContentLength is null or <= 0)
        {
            context.Response.StatusCode = StatusCodes.Status400BadRequest;
            await context.Response.WriteAsync("Offer body required", context.RequestAborted);
            return;
        }
        if (context.Request.ContentLength > MaximumOfferBytes)
        {
            context.Response.StatusCode = StatusCodes.Status413PayloadTooLarge;
            await context.Response.WriteAsync("Offer payload too large", context.RequestAborted);
            return;
        }

        using var reader = new StreamReader(context.Request.Body, Encoding.UTF8, detectEncodingFromByteOrderMarks: false, leaveOpen: true);
        var json = await reader.ReadToEndAsync(context.RequestAborted);
        if (Encoding.UTF8.GetByteCount(json) > MaximumOfferBytes)
        {
            context.Response.StatusCode = StatusCodes.Status413PayloadTooLarge;
            await context.Response.WriteAsync("Offer payload too large", context.RequestAborted);
            return;
        }

        var remote = context.Connection.RemoteIpAddress;
        if (remote?.IsIPv4MappedToIPv6 == true) remote = remote.MapToIPv4();
        var offer = PeerOfferStore.ReceiveIncoming(remote?.ToString() ?? string.Empty, json);
        if (offer is null)
        {
            context.Response.StatusCode = StatusCodes.Status400BadRequest;
            await context.Response.WriteAsync("Invalid or expired offer", context.RequestAborted);
            return;
        }

        context.Response.Headers["X-FTPortal-Protocol"] = PeerProtocol.VersionV2;
        await context.Response.WriteAsJsonAsync(new
        {
            offerId = offer.OfferId,
            status = "pending",
            expiresAt = offer.ExpiresAt
        }, cancellationToken: context.RequestAborted);
    }

    private async Task SendHeadAsync(HttpContext context, string id)
    {
        if (!ValidId(id))
        {
            context.Response.StatusCode = StatusCodes.Status400BadRequest;
            return;
        }
        var available = _shares.Available(id);
        if (available is null)
        {
            context.Response.StatusCode = StatusCodes.Status410Gone;
            return;
        }
        if (!File.Exists(available.Path))
        {
            _shares.Remove(id);
            context.Response.StatusCode = StatusCodes.Status410Gone;
            return;
        }
        SetDownloadHeaders(context, available, new FileInfo(available.Path).Length, protocolVersion: null);
        await Task.CompletedTask;
    }

    private async Task SendOneShotAsync(
        HttpContext context,
        string id,
        string? protocolVersion,
        Action? onCompleted = null)
    {
        if (!ValidId(id))
        {
            context.Response.StatusCode = StatusCodes.Status400BadRequest;
            await context.Response.WriteAsync("Invalid share id", context.RequestAborted);
            return;
        }

        var file = _shares.Claim(id);
        if (file is null)
        {
            context.Response.StatusCode = StatusCodes.Status410Gone;
            await context.Response.WriteAsync("Share already consumed, busy, or unavailable", context.RequestAborted);
            return;
        }
        if (!File.Exists(file.Path))
        {
            _shares.Consume(id);
            context.Response.StatusCode = StatusCodes.Status410Gone;
            await context.Response.WriteAsync("Source file unavailable", context.RequestAborted);
            return;
        }

        var transferId = string.Empty;
        var transferred = 0L;
        try
        {
            await using var source = new FileStream(
                file.Path,
                FileMode.Open,
                FileAccess.Read,
                FileShare.Read,
                128 * 1024,
                FileOptions.Asynchronous | FileOptions.SequentialScan
            );
            var currentSize = source.Length;
            transferId = _transfers.Begin(
                TransferDirection.Send,
                file.Name,
                RemotePeer(context),
                currentSize
            );
            using var transferCancellation = CancellationTokenSource.CreateLinkedTokenSource(
                context.RequestAborted,
                _transfers.Token(transferId)
            );
            var transferToken = transferCancellation.Token;
            SetDownloadHeaders(context, file, currentSize, protocolVersion);

            var buffer = ArrayPool<byte>.Shared.Rent(128 * 1024);
            try
            {
                var remaining = currentSize;
                while (remaining > 0)
                {
                    var read = await source.ReadAsync(
                        buffer.AsMemory(0, (int)Math.Min(buffer.Length, remaining)),
                        transferToken
                    );
                    if (read == 0) break;
                    await context.Response.Body.WriteAsync(buffer.AsMemory(0, read), transferToken);
                    transferred += read;
                    remaining -= read;
                    _transfers.Update(transferId, transferred);
                }

                if (remaining != 0)
                {
                    _shares.Release(id);
                    _transfers.Finish(transferId, success: false, detail: "Source changed during transfer", finalBytes: transferred);
                    return;
                }

                await context.Response.Body.FlushAsync(transferToken);
            }
            finally
            {
                ArrayPool<byte>.Shared.Return(buffer);
            }

            if (transferToken.IsCancellationRequested)
            {
                _shares.Release(id);
                _transfers.Finish(transferId, success: false, detail: "Connection interrupted", finalBytes: transferred);
            }
            else
            {
                _shares.Consume(id);
                try { onCompleted?.Invoke(); } catch { }
                _transfers.Finish(transferId, success: true, finalBytes: transferred);
            }
        }
        catch (OperationCanceledException)
        {
            _shares.Release(id);
            if (transferId.Length > 0)
                _transfers.Finish(transferId, success: false, detail: "Connection interrupted", finalBytes: transferred);
        }
        catch (Exception ex)
        {
            _shares.Release(id);
            if (transferId.Length > 0)
                _transfers.Finish(transferId, success: false, detail: TransferError(ex), finalBytes: transferred);
            if (!context.Response.HasStarted && !context.RequestAborted.IsCancellationRequested)
            {
                context.Response.StatusCode = StatusCodes.Status500InternalServerError;
                await context.Response.WriteAsync("Transfer failed", CancellationToken.None);
            }
        }
    }

    private static string RemotePeer(HttpContext context)
    {
        var address = context.Connection.RemoteIpAddress;
        if (address?.IsIPv4MappedToIPv6 == true) address = address.MapToIPv4();
        return address?.ToString() ?? "Local network peer";
    }

    private static string TransferError(Exception error) => error switch
    {
        UnauthorizedAccessException => "Source access denied",
        FileNotFoundException or DirectoryNotFoundException => "Source file unavailable",
        IOException => "Source I/O error",
        _ => "Transfer failed"
    };

    private static bool IsPortBindFailure(Exception error)
    {
        for (var current = error; current is not null; current = current.InnerException)
        {
            if (current is IOException or SocketException) return true;
        }
        return false;
    }

    private static string ShortError(Exception error) =>
        string.IsNullOrWhiteSpace(error.Message) ? error.GetType().Name : error.Message;

    private static bool ValidId(string id) =>
        !string.IsNullOrWhiteSpace(id) && id.Length <= 64 && id.All(Uri.IsHexDigit);

    private static void SetDownloadHeaders(HttpContext context, SharedFile file, long length, string? protocolVersion)
    {
        context.Response.ContentType = file.Mime;
        context.Response.ContentLength = length;
        context.Response.Headers["Content-Disposition"] = $"attachment; filename=\"download\"; filename*=UTF-8''{Uri.EscapeDataString(file.Name)}";
        context.Response.Headers["X-FTPortal-One-Shot"] = "true";
        if (!string.IsNullOrWhiteSpace(protocolVersion)) context.Response.Headers["X-FTPortal-Protocol"] = protocolVersion;
    }

    private string Html()
    {
        var encoder = HtmlEncoder.Default;
        var rows = string.Join("", _shares.All().Select(file =>
            $"<a class='file' href='/download/{file.Id}'><b>{encoder.Encode(file.Name)}</b><span>{file.Size:N0} bytes</span></a>"));
        if (rows.Length == 0) rows = "<p>No file is currently shared.</p>";

        return "<!doctype html><html><head><meta name='viewport' content='width=device-width,initial-scale=1'><meta http-equiv='refresh' content='4'><title>FTPortal Windows</title>" +
               "<style>body{font-family:Segoe UI,sans-serif;background:#0d1117;color:#e6edf3;max-width:760px;margin:50px auto;padding:20px}.file{display:flex;justify-content:space-between;padding:18px;margin:10px 0;border:1px solid #30363d;border-radius:12px;color:#58a6ff;text-decoration:none;background:#161b22}.file span,p{color:#8b949e}</style>" +
               "</head><body><h1>FTPortal</h1><p>Windows one-shot host · completed downloads consume the share.</p>" + rows + "</body></html>";
    }

    public async ValueTask DisposeAsync()
    {
        if (_peerApp is not null)
        {
            var peer = _peerApp;
            _peerApp = null;
            await peer.StopAsync();
            await peer.DisposeAsync();
        }
        if (_legacyApp is not null)
        {
            var legacy = _legacyApp;
            _legacyApp = null;
            Port = 0;
            await legacy.StopAsync();
            await legacy.DisposeAsync();
        }
    }
}
