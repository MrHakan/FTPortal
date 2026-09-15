using System.Text.Json;
using System.Text.Json.Serialization;

namespace FTPortal.Windows;

internal enum TransferDirection
{
    Send,
    Receive
}

internal sealed record TransferSnapshot(
    string Id,
    TransferDirection Direction,
    string FileName,
    string Peer,
    long BytesTransferred,
    long TotalBytes,
    int? ProgressPercent,
    double BytesPerSecond,
    long? EtaSeconds,
    DateTimeOffset StartedAt
);

internal sealed record TransferHistoryEntry(
    string Id,
    TransferDirection Direction,
    string FileName,
    string Peer,
    long BytesTransferred,
    long TotalBytes,
    DateTimeOffset StartedAt,
    DateTimeOffset FinishedAt,
    bool Success,
    string? Detail
);

/// <summary>
/// Process-local active transfer state plus a bounded, metadata-only history.
/// File contents, paths, bearer tokens and authorization data are deliberately
/// excluded from the persisted history.
/// </summary>
internal sealed class TransferCenter
{
    private const int MaximumHistory = 100;
    private const int MaximumTextLength = 240;

    private readonly object _gate = new();
    private readonly Dictionary<string, MutableTransfer> _active = new(StringComparer.Ordinal);
    private readonly List<TransferHistoryEntry> _history = [];
    private readonly string _historyPath;
    private readonly JsonSerializerOptions _jsonOptions = new(JsonSerializerDefaults.Web)
    {
        WriteIndented = false,
        Converters = { new JsonStringEnumConverter() }
    };

    public TransferCenter()
    {
        var directory = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "FTPortal"
        );
        Directory.CreateDirectory(directory);
        _historyPath = Path.Combine(directory, "transfer-history.json");
        Load();
    }

    public string Begin(
        TransferDirection direction,
        string fileName,
        string peer,
        long totalBytes)
    {
        var id = Guid.NewGuid().ToString("N");
        var now = DateTimeOffset.UtcNow;
        var transfer = new MutableTransfer(
            id,
            direction,
            LimitText(string.IsNullOrWhiteSpace(fileName) ? "Unnamed file" : fileName),
            LimitText(string.IsNullOrWhiteSpace(peer) ? "Local network peer" : peer),
            totalBytes,
            now
        );

        lock (_gate) _active[id] = transfer;
        return id;
    }

    public void Update(string id, long absoluteBytes)
    {
        MutableTransfer? transfer;
        lock (_gate) _active.TryGetValue(id, out transfer);
        if (transfer is null) return;

        lock (transfer.Gate)
        {
            var bytes = Math.Max(0L, absoluteBytes);
            var now = DateTimeOffset.UtcNow;
            var deltaBytes = bytes - transfer.LastSampleBytes;
            var deltaSeconds = (now - transfer.LastSampleAt).TotalSeconds;
            transfer.BytesTransferred = bytes;

            if (deltaBytes >= 0 && deltaSeconds >= 0.18)
            {
                var instant = deltaBytes / deltaSeconds;
                transfer.SmoothedBytesPerSecond = transfer.SmoothedBytesPerSecond <= 0
                    ? instant
                    : transfer.SmoothedBytesPerSecond * 0.72 + instant * 0.28;
                transfer.LastSampleBytes = bytes;
                transfer.LastSampleAt = now;
            }
        }
    }

    public CancellationToken Token(string id)
    {
        lock (_gate)
            return _active.TryGetValue(id, out var transfer)
                ? transfer.Cancellation.Token
                : CancellationToken.None;
    }

    public bool Cancel(string id)
    {
        MutableTransfer? transfer;
        lock (_gate) _active.TryGetValue(id, out transfer);
        if (transfer is null) return false;
        transfer.Cancellation.Cancel();
        return true;
    }

    public int CancelAll()
    {
        MutableTransfer[] transfers;
        lock (_gate) transfers = _active.Values.ToArray();
        foreach (var transfer in transfers) transfer.Cancellation.Cancel();
        return transfers.Length;
    }

    public void Finish(string id, bool success, string? detail = null, long? finalBytes = null)
    {
        MutableTransfer? transfer;
        lock (_gate)
        {
            if (!_active.Remove(id, out transfer)) return;

            lock (transfer.Gate)
            {
                if (finalBytes.HasValue) transfer.BytesTransferred = Math.Max(0L, finalBytes.Value);
                _history.Insert(0, new TransferHistoryEntry(
                    transfer.Id,
                    transfer.Direction,
                    transfer.FileName,
                    transfer.Peer,
                    transfer.BytesTransferred,
                    transfer.TotalBytes,
                    transfer.StartedAt,
                    DateTimeOffset.UtcNow,
                    success,
                    string.IsNullOrWhiteSpace(detail) ? null : LimitText(detail)
                ));
            }

            if (_history.Count > MaximumHistory)
                _history.RemoveRange(MaximumHistory, _history.Count - MaximumHistory);

            PersistLocked();
        }
    }

    public IReadOnlyList<TransferSnapshot> Active()
    {
        lock (_gate)
        {
            return _active.Values
                .Select(ToSnapshot)
                .OrderBy(transfer => transfer.StartedAt)
                .ToArray();
        }
    }

    public IReadOnlyList<TransferHistoryEntry> History()
    {
        lock (_gate) return _history.ToArray();
    }

    public void ClearHistory()
    {
        lock (_gate)
        {
            _history.Clear();
            PersistLocked();
        }
    }

    private TransferSnapshot ToSnapshot(MutableTransfer transfer)
    {
        lock (transfer.Gate)
        {
            var bytes = transfer.BytesTransferred;
            var total = transfer.TotalBytes;
            var percent = total > 0
                ? (int)Math.Clamp(bytes * 100d / total, 0d, 100d)
                : null;
            var eta = total > 0 && transfer.SmoothedBytesPerSecond > 1 && bytes < total
                ? (long?)Math.Max(0, (total - bytes) / transfer.SmoothedBytesPerSecond)
                : null;

            return new TransferSnapshot(
                transfer.Id,
                transfer.Direction,
                transfer.FileName,
                transfer.Peer,
                bytes,
                total,
                percent,
                transfer.SmoothedBytesPerSecond,
                eta,
                transfer.StartedAt
            );
        }
    }

    private void Load()
    {
        if (!File.Exists(_historyPath)) return;

        try
        {
            var saved = JsonSerializer.Deserialize<List<TransferHistoryEntry>>(
                File.ReadAllText(_historyPath),
                _jsonOptions
            ) ?? [];
            _history.AddRange(saved.Take(MaximumHistory));
        }
        catch
        {
            // A damaged history must never prevent the local host from starting.
            _history.Clear();
        }
    }

    private void PersistLocked()
    {
        try
        {
            var temporary = _historyPath + ".tmp";
            var json = JsonSerializer.Serialize(_history, _jsonOptions);
            File.WriteAllText(temporary, json);
            File.Move(temporary, _historyPath, overwrite: true);
        }
        catch
        {
            // History is an auxiliary feature; transfer availability must win.
        }
    }

    private static string LimitText(string value) => value.Length <= MaximumTextLength
        ? value
        : value[..MaximumTextLength];

    private sealed class MutableTransfer(
        string id,
        TransferDirection direction,
        string fileName,
        string peer,
        long totalBytes,
        DateTimeOffset startedAt)
    {
        public object Gate { get; } = new();
        public string Id { get; } = id;
        public TransferDirection Direction { get; } = direction;
        public string FileName { get; } = fileName;
        public string Peer { get; } = peer;
        public long TotalBytes { get; } = totalBytes;
        public DateTimeOffset StartedAt { get; } = startedAt;
        public CancellationTokenSource Cancellation { get; } = new();
        public long BytesTransferred { get; set; }
        public long LastSampleBytes { get; set; }
        public DateTimeOffset LastSampleAt { get; set; } = startedAt;
        public double SmoothedBytesPerSecond { get; set; }
    }
}
