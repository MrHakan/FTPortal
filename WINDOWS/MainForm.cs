using System.Diagnostics;
using System.Net.Http;
using System.Security.Cryptography;

namespace FTPortal.Windows;

internal sealed class MainForm : Form
{
    private static readonly HttpClient PeerTransferClient = new(new SocketsHttpHandler { UseProxy = false })
    {
        Timeout = Timeout.InfiniteTimeSpan
    };

    private readonly ShareRegistry _shares = new();
    private readonly NetworkTransportManager _network = new();
    private readonly PortalServer _server;
    private MdnsResponder? _mdns;

    private readonly Label _address = new() { AutoSize = true, Font = new Font("Segoe UI", 11, FontStyle.Bold) };
    private readonly Label _transport = new() { AutoSize = true };
    private readonly Label _discovery = new() { AutoSize = true, ForeColor = Color.DimGray };
    private readonly Label _notice = new() { AutoSize = true, ForeColor = Color.DimGray };
    private readonly ListBox _files = new() { Dock = DockStyle.Fill, SelectionMode = SelectionMode.MultiExtended };
    private readonly ListBox _lobbies = new() { Dock = DockStyle.Fill, SelectionMode = SelectionMode.One };
    private readonly System.Windows.Forms.Timer _timer = new() { Interval = 3000 };
    private readonly NotifyIcon _tray = new();
    private IReadOnlyList<SharedFile> _visibleShares = [];
    private IReadOnlyList<PeerLobby> _visibleLobbies = [];
    private bool _allowExit;
    private bool _scanInProgress;
    private DateTime _lastLobbyScan = DateTime.MinValue;
    private readonly string _ssid = "FTPHAKAN-" + Convert.ToHexString(RandomNumberGenerator.GetBytes(2));
    private readonly string _pass = Convert.ToHexString(RandomNumberGenerator.GetBytes(6));

    public MainForm()
    {
        Text = "FTPortal · Windows";
        Width = 900;
        Height = 650;
        MinimumSize = new Size(720, 500);
        StartPosition = FormStartPosition.CenterScreen;
        _server = new PortalServer(_shares);

        var add = new Button { Text = "Share file", AutoSize = true };
        add.Click += (_, _) => AddFile();
        var cancel = new Button { Text = "Cancel selected share", AutoSize = true };
        cancel.Click += (_, _) => CancelSelectedShares();
        var clear = new Button { Text = "Clear pending shares", AutoSize = true };
        clear.Click += (_, _) => ClearPendingShares();
        var refreshLobbies = new Button { Text = "Refresh lobbies", AutoSize = true };
        refreshLobbies.Click += async (_, _) => await RefreshLobbiesAsync(force: true);
        var joinLobby = new Button { Text = "Join selected lobby", AutoSize = true };
        joinLobby.Click += (_, _) => JoinSelectedLobby();
        var browser = new Button { Text = "Open browser dashboard", AutoSize = true };
        browser.Click += (_, _) => OpenDashboard();
        var hotspot = new Button { Text = "Start hotspot fallback", AutoSize = true };
        hotspot.Click += async (_, _) => _notice.Text = await _network.StartHotspotAsync(_ssid, _pass);
        var stopHotspot = new Button { Text = "Stop hotspot", AutoSize = true };
        stopHotspot.Click += async (_, _) => _notice.Text = await _network.StopHotspotAsync();

        var buttons = new FlowLayoutPanel
        {
            Dock = DockStyle.Top,
            AutoSize = true,
            WrapContents = true,
            Padding = new Padding(0, 8, 0, 8)
        };
        buttons.Controls.AddRange([add, cancel, clear, refreshLobbies, joinLobby, browser, hotspot, stopHotspot]);

        var header = new FlowLayoutPanel
        {
            Dock = DockStyle.Top,
            FlowDirection = FlowDirection.TopDown,
            AutoSize = true,
            WrapContents = false,
            Padding = new Padding(12)
        };
        header.Controls.Add(new Label { Text = "FTPortal", AutoSize = true, Font = new Font("Segoe UI", 24, FontStyle.Bold) });
        header.Controls.Add(_address);
        header.Controls.Add(_transport);
        header.Controls.Add(_discovery);
        header.Controls.Add(new Label { Text = $"Hotspot fallback: SSID {_ssid} · password {_pass}", AutoSize = true });
        header.Controls.Add(_notice);
        header.Controls.Add(buttons);

        var mySharesGroup = new GroupBox { Text = "My one-shot shares", Dock = DockStyle.Fill, Padding = new Padding(8) };
        mySharesGroup.Controls.Add(_files);
        var lobbiesGroup = new GroupBox { Text = "Nearby FTPortal lobbies", Dock = DockStyle.Fill, Padding = new Padding(8) };
        lobbiesGroup.Controls.Add(_lobbies);
        _lobbies.DoubleClick += (_, _) => JoinSelectedLobby();

        var lists = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            RowCount = 2,
            ColumnCount = 1,
            Padding = new Padding(12, 0, 12, 12)
        };
        lists.RowStyles.Add(new RowStyle(SizeType.Percent, 52));
        lists.RowStyles.Add(new RowStyle(SizeType.Percent, 48));
        lists.Controls.Add(mySharesGroup, 0, 0);
        lists.Controls.Add(lobbiesGroup, 0, 1);

        Controls.Add(lists);
        Controls.Add(header);

        _tray.Icon = SystemIcons.Application;
        _tray.Text = "FTPortal";
        _tray.Visible = true;
        _tray.DoubleClick += (_, _) => RestoreWindow();
        var menu = new ContextMenuStrip();
        menu.Items.Add("Open dashboard", null, (_, _) => RestoreWindow());
        menu.Items.Add("Open browser", null, (_, _) => OpenDashboard());
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Exit FTPortal", null, async (_, _) => await ExitAsync());
        _tray.ContextMenuStrip = menu;

        FormClosing += OnFormClosing;
        Shown += async (_, _) => await StartAsync();
        _timer.Tick += async (_, _) =>
        {
            RefreshDashboard();
            await RefreshLobbiesAsync(force: false);
        };
        _timer.Start();
    }

    private async Task StartAsync()
    {
        try
        {
            await _server.StartAsync(80, 8080, 8787);
            _mdns = new MdnsResponder(() => _network.Primary()?.Address);
            _mdns.Start();
            RefreshDashboard();
            await RefreshLobbiesAsync(force: true);

            var transports = _network.Snapshot();
            if (transports.Count == 0 || transports.All(x => x.Priority >= 2))
                _notice.Text = await _network.StartHotspotAsync(_ssid, _pass);
        }
        catch (Exception ex)
        {
            _notice.Text = "Server failed: " + ex.Message;
        }
    }

    private void AddFile()
    {
        using var dialog = new OpenFileDialog { Multiselect = true, Title = "Select one-shot files" };
        if (dialog.ShowDialog(this) != DialogResult.OK) return;

        foreach (var path in dialog.FileNames)
        {
            try { _shares.Add(path); }
            catch (Exception ex) { _notice.Text = $"Could not share {Path.GetFileName(path)}: {ex.Message}"; }
        }
        RefreshDashboard();
    }

    private void CancelSelectedShares()
    {
        var ids = _files.SelectedIndices
            .Cast<int>()
            .Where(index => index >= 0 && index < _visibleShares.Count)
            .Select(index => _visibleShares[index].Id)
            .ToArray();
        if (ids.Length == 0) return;

        foreach (var id in ids) _shares.Remove(id);
        _notice.Text = ids.Length == 1
            ? "Share link cancelled. Original file was not deleted."
            : $"{ids.Length} share links cancelled. Original files were not deleted.";
        RefreshDashboard();
    }

    private void ClearPendingShares()
    {
        if (_shares.All().Count == 0) return;
        var result = MessageBox.Show(
            this,
            "Remove all pending FTPortal share links? Original files will not be deleted.",
            "Clear pending shares",
            MessageBoxButtons.YesNo,
            MessageBoxIcon.Warning
        );
        if (result != DialogResult.Yes) return;

        _shares.ClearPending();
        _notice.Text = "Pending share links cleared. Original files were not deleted.";
        RefreshDashboard();
    }

    private void RefreshDashboard()
    {
        var primary = _network.Primary();
        if (primary is null || _server.Port == 0)
        {
            _address.Text = "No active local IPv4 transport";
            _transport.Text = "Waiting for Wi-Fi / LAN / hotspot";
        }
        else
        {
            var suffix = _server.Port == 80 ? "" : $":{_server.Port}";
            var mdnsAddress = _mdns?.IsRunning == true ? $"    ·    http://ftphakan.local{suffix}" : "";
            _address.Text = $"Web fallback: http://{primary.Address}{suffix}{mdnsAddress}";
            _transport.Text = $"Primary: {primary.Kind} ({primary.Adapter}) · fallback order: Wi-Fi → LAN → Hotspot";
        }

        var peerText = _server.PeerAvailable
            ? $"Peer protocol: {PeerProtocol.Version} on TCP {PeerProtocol.Port}"
            : $"Peer protocol unavailable on TCP {PeerProtocol.Port}";
        var mdnsText = _mdns switch
        {
            null => "mDNS has not started",
            { IsRunning: true } => "ftphakan.local active",
            _ => "mDNS unavailable" + (string.IsNullOrWhiteSpace(_mdns.LastError) ? "" : $": {_mdns.LastError}")
        };
        _discovery.Text = $"{peerText} · {mdnsText}";

        _visibleShares = _shares.All();
        var items = _visibleShares.Select(file => $"{file.Name}  ·  {file.Size:N0} bytes  ·  one-shot").ToArray();
        _files.BeginUpdate();
        _files.Items.Clear();
        _files.Items.AddRange(items);
        _files.EndUpdate();
    }

    private async Task RefreshLobbiesAsync(bool force)
    {
        if (_scanInProgress) return;
        if (!force && DateTime.UtcNow - _lastLobbyScan < TimeSpan.FromSeconds(15)) return;
        _scanInProgress = true;
        _lastLobbyScan = DateTime.UtcNow;

        try
        {
            _notice.Text = "Scanning for FTPortal lobbies…";
            var addresses = _network.Snapshot().Select(item => item.Address).Distinct().ToArray();
            _visibleLobbies = await PeerDiscovery.DiscoverAsync(addresses);
            _lobbies.BeginUpdate();
            _lobbies.Items.Clear();
            _lobbies.Items.AddRange(_visibleLobbies.Select(lobby =>
                $"{lobby.Alias}  ·  {lobby.Platform}  ·  {lobby.Files.Count} file{(lobby.Files.Count == 1 ? "" : "s")}  ·  {lobby.Host}"
            ).ToArray());
            _lobbies.EndUpdate();
            _notice.Text = _visibleLobbies.Count == 0
                ? "No active FTPortal lobbies found."
                : $"Found {_visibleLobbies.Count} active FTPortal lobb{(_visibleLobbies.Count == 1 ? "y" : "ies")}.";
        }
        catch (Exception ex)
        {
            _notice.Text = "Lobby scan failed: " + ex.Message;
        }
        finally
        {
            _scanInProgress = false;
        }
    }

    private void JoinSelectedLobby()
    {
        var index = _lobbies.SelectedIndex;
        if (index < 0 || index >= _visibleLobbies.Count) return;
        ShowLobby(_visibleLobbies[index]);
    }

    private void ShowLobby(PeerLobby lobby)
    {
        using var dialog = new Form
        {
            Text = $"FTPortal Lobby · {lobby.Alias}",
            Width = 650,
            Height = 430,
            MinimumSize = new Size(520, 330),
            StartPosition = FormStartPosition.CenterParent
        };
        var info = new Label
        {
            Dock = DockStyle.Top,
            AutoSize = true,
            Padding = new Padding(10),
            Text = $"{lobby.Platform} · {lobby.Host}:{lobby.PeerPort} · {PeerProtocol.Version}\nChoose a one-shot file to receive directly from this device."
        };
        var list = new ListBox { Dock = DockStyle.Fill };
        list.Items.AddRange(lobby.Files.Select(file =>
            $"{file.Name}  ·  {(file.Size >= 0 ? $"{file.Size:N0} bytes" : "stream")}"
        ).ToArray());
        var download = new Button { Text = "Receive selected file", Dock = DockStyle.Bottom, Height = 42 };
        download.Click += async (_, _) =>
        {
            var selected = list.SelectedIndex;
            if (selected < 0 || selected >= lobby.Files.Count) return;
            download.Enabled = false;
            try
            {
                var completed = await DownloadPeerFileAsync(lobby, lobby.Files[selected]);
                if (completed)
                {
                    dialog.Close();
                    await RefreshLobbiesAsync(force: true);
                }
            }
            finally
            {
                if (!dialog.IsDisposed) download.Enabled = true;
            }
        };
        list.DoubleClick += async (_, _) =>
        {
            if (download.Enabled && list.SelectedIndex >= 0) download.PerformClick();
            await Task.CompletedTask;
        };

        dialog.Controls.Add(list);
        dialog.Controls.Add(download);
        dialog.Controls.Add(info);
        dialog.ShowDialog(this);
    }

    private async Task<bool> DownloadPeerFileAsync(PeerLobby lobby, PeerRemoteFile file)
    {
        using var save = new SaveFileDialog
        {
            Title = "Receive FTPortal file",
            FileName = SafeFileName(file.Name),
            Filter = "All files (*.*)|*.*",
            OverwritePrompt = true
        };
        if (save.ShowDialog(this) != DialogResult.OK) return false;

        var target = save.FileName;
        var temp = target + $".ftportal-{Guid.NewGuid():N}.part";
        try
        {
            using var request = new HttpRequestMessage(
                HttpMethod.Get,
                $"http://{lobby.Host}:{lobby.PeerPort}{PeerProtocol.DownloadPrefix}{file.Id}"
            );
            request.Headers.TryAddWithoutValidation("X-FTPortal-Client", PeerProtocol.Version);
            using var response = await PeerTransferClient.SendAsync(request, HttpCompletionOption.ResponseHeadersRead);
            if (!response.IsSuccessStatusCode)
                throw new IOException($"Peer returned HTTP {(int)response.StatusCode} {response.ReasonPhrase}");

            await using (var source = await response.Content.ReadAsStreamAsync())
            await using (var destination = new FileStream(temp, FileMode.CreateNew, FileAccess.Write, FileShare.None, 128 * 1024, useAsync: true))
            {
                await source.CopyToAsync(destination, 128 * 1024);
                await destination.FlushAsync();
            }

            File.Move(temp, target, overwrite: true);
            MessageBox.Show(this, $"Received {file.Name}", "FTPortal", MessageBoxButtons.OK, MessageBoxIcon.Information);
            return true;
        }
        catch (Exception ex)
        {
            try { if (File.Exists(temp)) File.Delete(temp); } catch { }
            MessageBox.Show(this, "Transfer failed: " + ex.Message, "FTPortal", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return false;
        }
    }

    private static string SafeFileName(string name)
    {
        var leaf = Path.GetFileName(name);
        if (string.IsNullOrWhiteSpace(leaf)) leaf = "FTPortal-download";
        foreach (var invalid in Path.GetInvalidFileNameChars()) leaf = leaf.Replace(invalid, '_');
        return leaf;
    }

    private void OpenDashboard()
    {
        var primary = _network.Primary();
        if (primary is null || _server.Port == 0) return;
        var suffix = _server.Port == 80 ? "" : $":{_server.Port}";
        Process.Start(new ProcessStartInfo($"http://{primary.Address}{suffix}") { UseShellExecute = true });
    }

    private void OnFormClosing(object? sender, FormClosingEventArgs e)
    {
        if (_allowExit) return;
        if (e.CloseReason == CloseReason.UserClosing)
        {
            e.Cancel = true;
            Hide();
            _tray.ShowBalloonTip(
                2000,
                "FTPortal is still running",
                "Right-click the tray icon and choose Exit FTPortal to stop the host.",
                ToolTipIcon.Info
            );
        }
    }

    private void RestoreWindow()
    {
        Show();
        WindowState = FormWindowState.Normal;
        Activate();
    }

    private async Task ExitAsync()
    {
        if (_allowExit) return;
        _allowExit = true;
        _timer.Stop();
        if (_mdns is not null) await _mdns.DisposeAsync();
        await _server.DisposeAsync();
        _tray.Visible = false;
        _tray.Dispose();
        Close();
    }
}
