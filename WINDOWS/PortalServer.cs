using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using System.Net.Sockets;
using System.Text.Encodings.Web;

namespace FTPortal.Windows;

internal sealed class PortalServer : IAsyncDisposable
{
    private readonly ShareRegistry _shares;
    private WebApplication? _app;

    public int Port { get; private set; }

    public PortalServer(ShareRegistry shares) => _shares = shares;

    public async Task<int> StartAsync(params int[] ports)
    {
        if (_app is not null) return Port;

        Exception? last = null;
        foreach (var port in ports.Distinct().Where(port => port is > 0 and <= 65535))
        {
            WebApplication? candidate = null;
            try
            {
                var builder = WebApplication.CreateBuilder(new WebApplicationOptions { Args = Array.Empty<string>() });
                builder.WebHost.ConfigureKestrel(options => options.ListenAnyIP(port));
                candidate = builder.Build();
                Configure(candidate);
                await candidate.StartAsync();
                _app = candidate;
                Port = port;
                return port;
            }
            catch (Exception ex) when (ex is IOException or SocketException)
            {
                last = ex;
                if (candidate is not null) await candidate.DisposeAsync();
            }
        }

        throw new IOException("No FTPortal port could be opened.", last);
    }

    private void Configure(WebApplication app)
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

        app.MapGet("/", () => Results.Content(Html(), "text/html; charset=utf-8"));
        app.MapGet("/api/state", () => Results.Json(new
        {
            files = _shares.All().Select(file => new { file.Id, file.Name, file.Size, file.Mime })
        }));

        app.MapMethods("/download/{id}", [HttpMethods.Get, HttpMethods.Head], async (HttpContext context, string id) =>
        {
            if (string.IsNullOrWhiteSpace(id) || id.Length > 64 || id.Any(c => !Uri.IsHexDigit(c)))
            {
                context.Response.StatusCode = StatusCodes.Status400BadRequest;
                await context.Response.WriteAsync("Invalid share id");
                return;
            }

            if (HttpMethods.IsHead(context.Request.Method))
            {
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

                SetDownloadHeaders(context, available, new FileInfo(available.Path).Length);
                return;
            }

            var file = _shares.Claim(id);
            if (file is null)
            {
                context.Response.StatusCode = StatusCodes.Status410Gone;
                await context.Response.WriteAsync("Share already consumed, busy, or unavailable");
                return;
            }

            if (!File.Exists(file.Path))
            {
                _shares.Consume(id);
                context.Response.StatusCode = StatusCodes.Status410Gone;
                await context.Response.WriteAsync("Source file unavailable");
                return;
            }

            try
            {
                var currentSize = new FileInfo(file.Path).Length;
                SetDownloadHeaders(context, file, currentSize);
                await context.Response.SendFileAsync(file.Path, context.RequestAborted);
                if (context.RequestAborted.IsCancellationRequested) _shares.Release(id);
                else _shares.Consume(id);
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
                    await context.Response.WriteAsync("Transfer failed");
                }
            }
        });
    }

    private static void SetDownloadHeaders(HttpContext context, SharedFile file, long length)
    {
        context.Response.ContentType = file.Mime;
        context.Response.ContentLength = length;
        context.Response.Headers["Content-Disposition"] = $"attachment; filename=\"download\"; filename*=UTF-8''{Uri.EscapeDataString(file.Name)}";
        context.Response.Headers["X-FTPortal-One-Shot"] = "true";
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
        if (_app is null) return;
        var app = _app;
        _app = null;
        Port = 0;
        await app.StopAsync();
        await app.DisposeAsync();
    }
}
