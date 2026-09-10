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
        Exception? last = null;
        foreach (var port in ports)
        {
            try
            {
                var builder = WebApplication.CreateBuilder(new WebApplicationOptions { Args = Array.Empty<string>() });
                builder.WebHost.ConfigureKestrel(options => options.ListenAnyIP(port));
                var app = builder.Build();
                Configure(app);
                await app.StartAsync();
                _app = app;
                Port = port;
                return port;
            }
            catch (Exception ex) when (ex is IOException or SocketException)
            {
                last = ex;
            }
        }
        throw new IOException("No FTPortal port could be opened.", last);
    }

    private void Configure(WebApplication app)
    {
        app.MapGet("/", () => Results.Content(Html(), "text/html; charset=utf-8"));
        app.MapGet("/api/state", () => Results.Json(new { files = _shares.All().Select(x => new { x.Id, x.Name, x.Size }) }));
        app.MapGet("/download/{id}", async (HttpContext context, string id) =>
        {
            var file = _shares.Get(id);
            if (file is null || !File.Exists(file.Path))
            {
                context.Response.StatusCode = StatusCodes.Status410Gone;
                await context.Response.WriteAsync("Share already consumed or unavailable");
                return;
            }

            context.Response.ContentType = file.Mime;
            context.Response.ContentLength = file.Size;
            context.Response.Headers["Content-Disposition"] = $"attachment; filename*=UTF-8''{Uri.EscapeDataString(file.Name)}";
            context.Response.Headers["Cache-Control"] = "no-store";
            context.Response.Headers["X-FTPortal-One-Shot"] = "true";
            try
            {
                await context.Response.SendFileAsync(file.Path, context.RequestAborted);
                if (!context.RequestAborted.IsCancellationRequested) _shares.Consume(id);
            }
            catch (OperationCanceledException) { }
        });
    }

    private string Html()
    {
        var encoder = HtmlEncoder.Default;
        var rows = string.Join("", _shares.All().Select(file => $"<a class='file' href='/download/{file.Id}'><b>{encoder.Encode(file.Name)}</b><span>{file.Size:N0} bytes</span></a>"));
        if (rows.Length == 0) rows = "<p>No file is currently shared.</p>";
        return "<!doctype html><html><head><meta name='viewport' content='width=device-width,initial-scale=1'><meta http-equiv='refresh' content='4'><title>FTPortal Windows</title>" +
               "<style>body{font-family:Segoe UI,sans-serif;background:#0d1117;color:#e6edf3;max-width:760px;margin:50px auto;padding:20px}.file{display:flex;justify-content:space-between;padding:18px;margin:10px 0;border:1px solid #30363d;border-radius:12px;color:#58a6ff;text-decoration:none;background:#161b22}.file span,p{color:#8b949e}</style>" +
               "</head><body><h1>FTPortal</h1><p>Windows one-shot host · completed downloads consume the share.</p>" + rows + "</body></html>";
    }

    public async ValueTask DisposeAsync()
    {
        if (_app is not null)
        {
            await _app.StopAsync();
            await _app.DisposeAsync();
        }
    }
}
