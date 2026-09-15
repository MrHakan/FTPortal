namespace FTPortal.Windows;

/// <summary>
/// Re-arms the Windows Mobile Hotspot fallback when every usable local
/// transport disappears. Attempts are serialized and exponentially backed off
/// so an unavailable Windows tethering API cannot become a tight retry loop.
/// </summary>
internal sealed class TransportSupervisor : IDisposable
{
    private readonly NetworkTransportManager _network;
    private readonly string _ssid;
    private readonly string _passphrase;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private DateTimeOffset _nextAttempt = DateTimeOffset.MinValue;
    private int _attempts;
    private bool _automaticFallbackEnabled = true;

    public TransportSupervisor(NetworkTransportManager network, string ssid, string passphrase)
    {
        _network = network;
        _ssid = ssid;
        _passphrase = passphrase;
    }

    public async Task<string?> EnsureFallbackAsync(bool force = false, CancellationToken cancellationToken = default)
    {
        if (!await _gate.WaitAsync(0, cancellationToken)) return null;
        try
        {
            if (_network.Snapshot().Count > 0)
            {
                _attempts = 0;
                _automaticFallbackEnabled = true;
                return null;
            }

            var now = DateTimeOffset.UtcNow;
            if (!_automaticFallbackEnabled && now >= _nextAttempt) _automaticFallbackEnabled = true;
            if (!force && (!_automaticFallbackEnabled || now < _nextAttempt)) return null;

            var result = await _network.StartHotspotAsync(_ssid, _passphrase);
            _attempts = Math.Min(_attempts + 1, 6);
            var delaySeconds = Math.Min(120, 2 * Math.Pow(2, _attempts));
            _nextAttempt = DateTimeOffset.UtcNow.AddSeconds(delaySeconds);
            return result;
        }
        finally
        {
            _gate.Release();
        }
    }

    public async Task<string> StartManualFallbackAsync(CancellationToken cancellationToken = default)
    {
        if (!await _gate.WaitAsync(0, cancellationToken)) return "A hotspot operation is already in progress.";
        try
        {
            _automaticFallbackEnabled = true;
            _nextAttempt = DateTimeOffset.MinValue;
            return await _network.StartHotspotAsync(_ssid, _passphrase);
        }
        finally
        {
            _gate.Release();
        }
    }

    public async Task<string> StopManualFallbackAsync(CancellationToken cancellationToken = default)
    {
        if (!await _gate.WaitAsync(0, cancellationToken)) return "A hotspot operation is already in progress.";
        try
        {
            _automaticFallbackEnabled = false;
            _nextAttempt = DateTimeOffset.UtcNow.AddMinutes(10);
            return await _network.StopHotspotAsync();
        }
        finally
        {
            _gate.Release();
        }
    }

    public void Dispose() => _gate.Dispose();
}
