using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Http.Features;
using System.Buffers;
using System.Net.Sockets;
using System.Text;
using System.Text.Encodings.Web;

namespace FTPortal.Windows;

internal sealed class PortalServer : IAsyncDisposable
{
    private const int MaximumOfferBytes = 128 * 1024;
    private const long MaximumBrowserUploadBytes = 8L * 1024 * 1024 * 1024;
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
        builder.Services.Configure<FormOptions>(options =>
        {
            options.MultipartBodyLengthLimit = MaximumBrowserUploadBytes + 1024 * 1024;
            options.ValueLengthLimit = 16 * 1024;
            options.MultipartHeadersLengthLimit = 32 * 1024;
        });
        builder.WebHost.ConfigureKestrel(options =>
        {
            options.ListenAnyIP(port);
            // Browser form data has a small multipart envelope in addition to
            // the file.  Keep the hard limit explicit instead of accepting an
            // unbounded request body from a local client.
            options.Limits.MaxRequestBodySize = MaximumBrowserUploadBytes + 1024 * 1024;
        });
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
            context.Response.Headers["Content-Security-Policy"] = "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'self'; base-uri 'none'; form-action 'self'";

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
        app.MapPost("/upload", ReceiveBrowserUploadAsync);
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

    private async Task ReceiveBrowserUploadAsync(HttpContext context)
    {
        if (!context.Request.HasFormContentType)
        {
            context.Response.StatusCode = StatusCodes.Status415UnsupportedMediaType;
            await context.Response.WriteAsJsonAsync(new { ok = false, error = "Multipart form data is required" }, context.RequestAborted);
            return;
        }
        if (context.Request.ContentLength is > MaximumBrowserUploadBytes + 1024 * 1024)
        {
            context.Response.StatusCode = StatusCodes.Status413PayloadTooLarge;
            await context.Response.WriteAsJsonAsync(new { ok = false, error = "File is too large for this portal" }, context.RequestAborted);
            return;
        }

        IFormFile? upload;
        try
        {
            var form = await context.Request.ReadFormAsync(context.RequestAborted);
            upload = form.Files.GetFile("file") ?? form.Files.FirstOrDefault();
        }
        catch (Exception)
        {
            context.Response.StatusCode = StatusCodes.Status400BadRequest;
            await context.Response.WriteAsJsonAsync(new { ok = false, error = "Could not read the upload" }, context.RequestAborted);
            return;
        }

        if (upload is null || upload.Length <= 0)
        {
            context.Response.StatusCode = StatusCodes.Status400BadRequest;
            await context.Response.WriteAsJsonAsync(new { ok = false, error = "No file was included" }, context.RequestAborted);
            return;
        }
        if (upload.Length > MaximumBrowserUploadBytes)
        {
            context.Response.StatusCode = StatusCodes.Status413PayloadTooLarge;
            await context.Response.WriteAsJsonAsync(new { ok = false, error = "File is too large for this portal" }, context.RequestAborted);
            return;
        }

        var fileName = SafeFileName(upload.FileName);
        var destination = CreateBrowserUploadPath(fileName);
        var transferId = _transfers.Begin(TransferDirection.Receive, fileName, RemotePeer(context), upload.Length);
        var transferred = 0L;
        try
        {
            using var cancellation = CancellationTokenSource.CreateLinkedTokenSource(
                context.RequestAborted,
                _transfers.Token(transferId)
            );
            var token = cancellation.Token;
            // The request and parsed IFormFile length were validated above;
            // IFormFile itself exposes its stream without a size parameter.
            await using var input = upload.OpenReadStream();
            await using var output = new FileStream(
                destination,
                FileMode.CreateNew,
                FileAccess.Write,
                FileShare.None,
                128 * 1024,
                FileOptions.Asynchronous | FileOptions.SequentialScan
            );
            var buffer = ArrayPool<byte>.Shared.Rent(128 * 1024);
            try
            {
                while (true)
                {
                    var read = await input.ReadAsync(buffer.AsMemory(), token);
                    if (read == 0) break;
                    await output.WriteAsync(buffer.AsMemory(0, read), token);
                    transferred += read;
                    _transfers.Update(transferId, transferred);
                }
                await output.FlushAsync(token);
            }
            finally
            {
                ArrayPool<byte>.Shared.Return(buffer);
            }

            if (transferred != upload.Length)
                throw new IOException("Upload length changed while receiving the file.");

            _transfers.Finish(transferId, success: true, finalBytes: transferred);
            await context.Response.WriteAsJsonAsync(new
            {
                ok = true,
                name = fileName,
                bytes = transferred,
                destination = "Downloads/FTPortal"
            }, cancellationToken: context.RequestAborted);
        }
        catch (OperationCanceledException)
        {
            TryDelete(destination);
            _transfers.Finish(transferId, success: false, detail: "Connection interrupted", finalBytes: transferred);
        }
        catch (Exception)
        {
            TryDelete(destination);
            _transfers.Finish(transferId, success: false, detail: "Could not save the uploaded file", finalBytes: transferred);
            if (!context.Response.HasStarted && !context.RequestAborted.IsCancellationRequested)
            {
                context.Response.StatusCode = StatusCodes.Status500InternalServerError;
                await context.Response.WriteAsJsonAsync(new { ok = false, error = "Could not save the uploaded file" }, CancellationToken.None);
            }
        }
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

    private static string SafeFileName(string? submittedName)
    {
        var leaf = Path.GetFileName(submittedName?.Replace('\\', '/') ?? string.Empty).Trim();
        if (leaf.Length == 0) return "received-file";

        var invalid = Path.GetInvalidFileNameChars();
        var clean = new string(leaf
            .Where(character => !char.IsControl(character) && Array.IndexOf(invalid, character) < 0)
            .ToArray())
            .Trim();
        if (clean.Length == 0 || clean is "." or "..") return "received-file";
        return clean.Length <= 180 ? clean : clean[..180];
    }

    private static string CreateBrowserUploadPath(string fileName)
    {
        var root = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            "Downloads",
            "FTPortal"
        );
        Directory.CreateDirectory(root);

        var candidate = Path.Combine(root, fileName);
        if (!File.Exists(candidate)) return candidate;

        var stem = Path.GetFileNameWithoutExtension(fileName);
        var extension = Path.GetExtension(fileName);
        for (var index = 2; index <= 9999; index++)
        {
            candidate = Path.Combine(root, $"{stem} ({index}){extension}");
            if (!File.Exists(candidate)) return candidate;
        }
        return Path.Combine(root, $"{Guid.NewGuid():N}-{fileName}");
    }

    private static void TryDelete(string path)
    {
        try { File.Delete(path); } catch { }
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
            $"<div class='file-row'><div class='file-copy'><strong>{encoder.Encode(file.Name)}</strong><span>{FormatBytes(file.Size)} · ONE-SHOT</span></div><a class='receive-button' href='/download/{file.Id}'>RECEIVE</a></div>"));
        if (rows.Length == 0)
            rows = "<div class='empty-state'><div class='empty-icon'>↓</div><strong>No file waiting</strong><span>Share a file from the FTPortal app and refresh this page.</span></div>";

        return $$$$"""
<!doctype html><html lang='en'><head><meta charset='utf-8'>
<meta name='viewport' content='width=device-width,initial-scale=1,viewport-fit=cover'>
<meta name='theme-color' content='#0d0f12'><title>FTPortal</title><style>
:root{--bg:#0d0f12;--card:#141720;--border:#1e2330;--accent:#4f8ef7;--accent2:#8e6cf7;--text:#e8ecf5;--muted:#5a6480;--ok:#4ff78e}
*{box-sizing:border-box;margin:0;padding:0}body{font-family:'Segoe UI',system-ui,sans-serif;background:var(--bg);color:var(--text);min-height:100vh}header{position:sticky;top:0;z-index:2;background:rgba(20,23,32,.92);backdrop-filter:blur(8px);border-bottom:1px solid var(--border);padding:14px 24px;display:flex;align-items:center;justify-content:space-between;gap:16px;flex-wrap:wrap}.brand{display:flex;align-items:center;gap:11px}.brand .icon{font-size:24px}.brand h1{font-size:16px;letter-spacing:.5px}.host-chip{display:flex;align-items:center;gap:8px;background:var(--bg);border:1px solid var(--border);padding:6px 12px;border-radius:20px;font-size:13px;color:var(--muted)}.dot{width:8px;height:8px;border-radius:50%;background:var(--ok);box-shadow:0 0 6px var(--ok)}main{max-width:1100px;margin:0 auto;padding:24px}.portal-grid{display:grid;grid-template-columns:1fr 1fr;gap:22px}.panel{background:var(--card);border:1px solid var(--border);border-radius:14px;padding:20px;overflow:hidden}.panel-title{display:flex;align-items:center;gap:10px;margin-bottom:8px}.panel-icon{width:32px;height:32px;display:grid;place-items:center;border-radius:9px;background:rgba(79,142,247,.15);color:var(--accent);font-size:18px;font-weight:700}.panel h3{font-size:13px;text-transform:uppercase;letter-spacing:1.5px;color:var(--muted)}.panel-sub{margin:0 0 16px;color:var(--muted);font-size:13px;line-height:1.5}.file-list{display:flex;flex-direction:column;gap:8px}.file-row{display:flex;align-items:center;gap:12px;padding:10px 13px;background:var(--bg);border:1px solid var(--border);border-radius:10px}.file-copy{min-width:0;flex:1}.file-copy strong{display:block;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-size:13px}.file-copy span{display:block;color:var(--muted);font-size:11px;margin-top:4px}.receive-button,.tx-button{border:0;text-decoration:none;border-radius:9px;padding:10px 13px;font-size:12px;font-weight:600;cursor:pointer}.receive-button{color:var(--accent);border:1px solid var(--border);background:transparent}.receive-button:hover{border-color:var(--accent)}.empty-state{min-height:146px;display:flex;flex-direction:column;align-items:center;justify-content:center;text-align:center;border:2px dashed var(--border);border-radius:12px;color:var(--muted);padding:18px}.empty-state strong{color:var(--text);font-size:14px;margin:6px 0}.empty-state span{font-size:12px;line-height:1.45;max-width:270px}.empty-icon{font-size:26px;color:var(--muted)}.drop-zone{min-height:146px;border:2px dashed var(--border);border-radius:12px;display:flex;flex-direction:column;align-items:center;justify-content:center;text-align:center;padding:18px;cursor:pointer;color:var(--muted);transition:all .2s}.drop-zone.active{border-color:var(--accent);background:rgba(79,142,247,.06);color:var(--text)}.drop-zone .arrow{font-size:28px;color:var(--accent);margin-bottom:7px}.drop-zone strong{font-size:14px;color:var(--text)}.drop-zone span{font-size:12px;margin-top:5px;max-width:270px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.tx-button{width:100%;margin-top:12px;padding:12px 16px;color:#fff;background:var(--accent)}.tx-button:hover{filter:brightness(1.1)}.tx-button:disabled{opacity:.5;cursor:not-allowed}.progress-wrap{display:none;margin-top:14px}.progress-line{height:8px;border-radius:30px;background:var(--bg);border:1px solid var(--border);overflow:hidden}.progress-bar{height:100%;width:0;background:linear-gradient(90deg,var(--accent),var(--accent2));transition:width .12s}.progress-meta{display:flex;justify-content:space-between;color:var(--muted);font-size:11px;margin-top:7px}.result{min-height:18px;color:var(--ok);font-size:12px;margin-top:10px}.foot{text-align:center;color:var(--muted);font-size:11px;margin-top:22px}@media(max-width:680px){header{padding:12px 14px}main{padding:14px}.portal-grid{grid-template-columns:1fr}.panel{padding:16px}}
</style></head><body>
<header><div class='brand'><span class='icon'>📁</span><h1>LOCAL FILE PORTAL</h1></div><div class='host-chip'><span class='dot'></span><b>Windows host</b></div></header>
<main><section class='portal-grid'>
  <article class='panel'><div class='panel-title'><div class='panel-icon'>↓</div><h3>RECEIVE FILE</h3></div><p class='panel-sub'>Choose a one-shot file shared by this Windows host.</p><div class='file-list'>{{{{rows}}}}</div></article>
  <article class='panel'><div class='panel-title'><div class='panel-icon'>↑</div><h3>TRANSMIT FILE</h3></div><p class='panel-sub'>Send one file directly to this Windows device.</p><input id='txFile' type='file' hidden><label id='dropZone' class='drop-zone' for='txFile'><div class='arrow'>↑</div><strong>Choose or drop a file</strong><span id='fileName'>Nothing selected</span></label><button id='txButton' class='tx-button' type='button' disabled>TRANSMIT FILE</button><div id='progressWrap' class='progress-wrap'><div class='progress-line'><div id='progressBar' class='progress-bar'></div></div><div class='progress-meta'><span id='progressText'>0%</span><span id='progressSize'></span></div></div><div id='result' class='result'></div></article>
</section><div class='foot'>LOCAL NETWORK · NO CLOUD · ONE-SHOT LINKS</div></main>
<script>(function(){var input=document.getElementById('txFile'),zone=document.getElementById('dropZone'),button=document.getElementById('txButton'),name=document.getElementById('fileName'),wrap=document.getElementById('progressWrap'),bar=document.getElementById('progressBar'),text=document.getElementById('progressText'),size=document.getElementById('progressSize'),result=document.getElementById('result'),selected=null;function fmt(bytes){if(bytes<1024)return bytes+' B';if(bytes<1048576)return(bytes/1024).toFixed(1)+' KB';if(bytes<1073741824)return(bytes/1048576).toFixed(1)+' MB';return(bytes/1073741824).toFixed(2)+' GB'}function choose(file){selected=file||null;name.textContent=selected?selected.name+' · '+fmt(selected.size):'Nothing selected';button.disabled=!selected;result.textContent=''}input.addEventListener('change',function(){choose(input.files&&input.files[0])});['dragenter','dragover'].forEach(function(ev){zone.addEventListener(ev,function(e){e.preventDefault();zone.classList.add('active')})});['dragleave','drop'].forEach(function(ev){zone.addEventListener(ev,function(e){e.preventDefault();zone.classList.remove('active')})});zone.addEventListener('drop',function(e){if(e.dataTransfer&&e.dataTransfer.files&&e.dataTransfer.files[0])choose(e.dataTransfer.files[0])});button.addEventListener('click',function(){if(!selected)return;var data=new FormData();data.append('file',selected,selected.name);var xhr=new XMLHttpRequest();xhr.open('POST','/upload',true);button.disabled=true;wrap.style.display='block';result.textContent='';xhr.upload.onprogress=function(e){if(!e.lengthComputable)return;var p=Math.min(100,Math.round(e.loaded/e.total*100));bar.style.width=p+'%';text.textContent=p+'%';size.textContent=fmt(e.loaded)+' / '+fmt(e.total)};xhr.onload=function(){button.disabled=false;if(xhr.status>=200&&xhr.status<300){bar.style.width='100%';text.textContent='100%';result.textContent='Received by Windows · Downloads/FTPortal';selected=null;input.value='';name.textContent='Nothing selected';button.disabled=true}else{var msg='Transfer failed';try{msg=JSON.parse(xhr.responseText).error||msg}catch(ignore){}result.textContent=msg}};xhr.onerror=function(){button.disabled=false;result.textContent='Connection interrupted'};xhr.send(data)})})();</script>
</body></html>
""";
    }

    private static string FormatBytes(long bytes) => bytes switch
    {
        < 0 => "STREAM",
        < 1024 => $"{bytes} B",
        < 1024 * 1024 => $"{bytes / 1024d:F1} KB",
        < 1024 * 1024 * 1024 => $"{bytes / (1024d * 1024d):F1} MB",
        _ => $"{bytes / (1024d * 1024d * 1024d):F2} GB"
    };

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
