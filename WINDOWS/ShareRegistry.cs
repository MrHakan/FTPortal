using System.Text.Json;

namespace FTPortal.Windows;

internal sealed record SharedFile(string Id, string Path, string Name, long Size, string Mime);

internal sealed class ShareRegistry
{
    private readonly object _gate = new();
    private readonly Dictionary<string, SharedFile> _files = new(StringComparer.Ordinal);
    private readonly HashSet<string> _claimed = new(StringComparer.Ordinal);
    private readonly string _statePath;

    public ShareRegistry()
    {
        var directory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "FTPortal");
        Directory.CreateDirectory(directory);
        _statePath = Path.Combine(directory, "shares.json");
        Load();
    }

    public SharedFile Add(string path)
    {
        var info = new FileInfo(path);
        if (!info.Exists) throw new FileNotFoundException("Source file does not exist.", path);

        var item = new SharedFile(
            Guid.NewGuid().ToString("N"),
            info.FullName,
            info.Name,
            info.Length,
            MimeFor(info.Extension)
        );
        lock (_gate)
        {
            _files[item.Id] = item;
            PersistLocked();
        }
        return item;
    }

    public SharedFile? Available(string id)
    {
        lock (_gate)
        {
            return !_claimed.Contains(id) && _files.TryGetValue(id, out var file) ? file : null;
        }
    }

    public SharedFile? Claim(string id)
    {
        lock (_gate)
        {
            if (_claimed.Contains(id) || !_files.TryGetValue(id, out var file)) return null;
            _claimed.Add(id);
            return file;
        }
    }

    public void Release(string id)
    {
        lock (_gate) _claimed.Remove(id);
    }

    public IReadOnlyList<SharedFile> All()
    {
        lock (_gate)
        {
            return _files
                .Where(pair => !_claimed.Contains(pair.Key))
                .Select(pair => pair.Value)
                .OrderBy(file => file.Name, StringComparer.OrdinalIgnoreCase)
                .ToArray();
        }
    }

    public void Consume(string id) => Remove(id);

    public void Remove(string id)
    {
        lock (_gate)
        {
            _claimed.Remove(id);
            if (_files.Remove(id)) PersistLocked();
        }
    }

    public void ClearPending()
    {
        lock (_gate)
        {
            var ids = _files.Keys.Where(id => !_claimed.Contains(id)).ToArray();
            if (ids.Length == 0) return;
            foreach (var id in ids) _files.Remove(id);
            PersistLocked();
        }
    }

    private void Load()
    {
        if (!File.Exists(_statePath)) return;
        try
        {
            var saved = JsonSerializer.Deserialize<List<SharedFile>>(File.ReadAllText(_statePath)) ?? [];
            var changed = false;
            foreach (var file in saved)
            {
                if (File.Exists(file.Path)) _files[file.Id] = file;
                else changed = true;
            }
            if (changed) PersistLocked();
        }
        catch
        {
            // Corrupt state must never prevent the host from starting.
            _files.Clear();
            TryDelete(_statePath);
        }
    }

    private void PersistLocked()
    {
        var temp = _statePath + ".tmp";
        var json = JsonSerializer.Serialize(_files.Values.OrderBy(file => file.Name, StringComparer.OrdinalIgnoreCase));
        File.WriteAllText(temp, json);
        File.Move(temp, _statePath, overwrite: true);
    }

    private static void TryDelete(string path)
    {
        try { File.Delete(path); } catch { }
    }

    private static string MimeFor(string ext) => ext.ToLowerInvariant() switch
    {
        ".txt" or ".md" or ".log" or ".csv" => "text/plain",
        ".html" or ".htm" => "text/html",
        ".json" => "application/json",
        ".jpg" or ".jpeg" => "image/jpeg",
        ".png" => "image/png",
        ".gif" => "image/gif",
        ".webp" => "image/webp",
        ".svg" => "image/svg+xml",
        ".pdf" => "application/pdf",
        ".zip" => "application/zip",
        ".mp3" => "audio/mpeg",
        ".mp4" => "video/mp4",
        ".webm" => "video/webm",
        _ => "application/octet-stream"
    };
}
