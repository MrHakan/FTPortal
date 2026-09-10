using System.Collections.Concurrent;

namespace FTPortal.Windows;

internal sealed record SharedFile(string Id, string Path, string Name, long Size, string Mime);

internal sealed class ShareRegistry
{
    private readonly ConcurrentDictionary<string, SharedFile> _files = new();

    public SharedFile Add(string path)
    {
        var info = new FileInfo(path);
        var item = new SharedFile(Guid.NewGuid().ToString("N"), info.FullName, info.Name, info.Length, MimeFor(info.Extension));
        _files[item.Id] = item;
        return item;
    }

    public SharedFile? Get(string id) => _files.TryGetValue(id, out var file) ? file : null;
    public IReadOnlyList<SharedFile> All() => _files.Values.OrderBy(x => x.Name, StringComparer.OrdinalIgnoreCase).ToArray();
    public void Consume(string id) => _files.TryRemove(id, out _);

    private static string MimeFor(string ext) => ext.ToLowerInvariant() switch
    {
        ".txt" or ".md" or ".log" => "text/plain",
        ".jpg" or ".jpeg" => "image/jpeg",
        ".png" => "image/png",
        ".pdf" => "application/pdf",
        ".zip" => "application/zip",
        _ => "application/octet-stream"
    };
}
