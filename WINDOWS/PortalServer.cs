using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using System.Net.Sockets;
using System.Text;
using System.Text.Encodings.Web;

namespace FTPortal.Windows;

internal sealed class PortalServer : IAsyncDisposable
{
    private const int MaximumOfferBytes = 128 * 1024;
    private readonly ShareRegistry _shares;
    private WebApplication? _legacyApp;
    private WebApplication? _peerApp;

    public int Port { get; private set; }
    public bool PeerAvailable => _peerApp is not null;

    public PortalServer(ShareRegistry shares) => _shares = shares;

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
            catch (Exception ex) when (ex is IOException or SocketException)
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
        }
        catch
        {
            if (candidate is not null) await candidate.DisposeAsync();
            _peerApp = null;
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
            files = _shares.All().Select(file => new { file.Id, file.Name, file.Size, file.Mime })
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

        try
        {
            var currentSize = new FileInfo(file.Path).Length;
            SetDownloadHeaders(context, file, currentSize, protocolVersion);
            await context.Response.SendFileAsync(file.Path, context.RequestAborted);
            if (context.RequestAborted.IsCancellationRequested)
            {
                _shares.Release(id);
            }
            else
            {
                _shares.Consume(id);
                onCompleted?.Invoke();
            }
        }
        catch (OperationCanceledException)
        {
            _shares.Release(id);
        }
        catch
        {
            _shares.Release(id);
            if (!context.Response.HasStarted)
            {
                context.Response.StatusCode = StatusCodes.Status500InternalServerError;
                await context.Response.WriteAsync("Transfer failed", context.RequestAborted);
            }
        }
    }

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
