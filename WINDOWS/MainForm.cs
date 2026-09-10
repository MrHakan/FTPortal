using System.Diagnostics;
using System.Security.Cryptography;

namespace FTPortal.Windows;

internal sealed class MainForm : Form
{
    private readonly ShareRegistry _shares = new();
    private readonly NetworkTransportManager _network = new();
    private readonly PortalServer _server;
    private MdnsResponder? _mdns;
    private readonly Label _address = new() { AutoSize = true, Font = new Font("Segoe UI", 11, FontStyle.Bold) };
    private readonly Label _transport = new() { AutoSize = true };
    private readonly Label _notice = new() { AutoSize = true, ForeColor = Color.DimGray };
    private readonly ListBox _files = new() { Dock = DockStyle.Fill };
    private readonly System.Windows.Forms.Timer _timer = new() { Interval = 3000 };
    private readonly NotifyIcon _tray = new();
    private bool _allowExit;
    private string _ssid = "FTPHAKAN-" + Convert.ToHexString(RandomNumberGenerator.GetBytes(2));
    private string _pass = Convert.ToHexString(RandomNumberGenerator.GetBytes(6));

    public MainForm()
    {
        Text = "FTPortal · Windows";
        Width = 760;
        Height = 520;
        StartPosition = FormStartPosition.CenterScreen;
        _server = new PortalServer(_shares);

        var add = new Button { Text = "Share file", AutoSize = true };
        add.Click += (_, _) => AddFile();
        var browser = new Button { Text = "Open browser dashboard", AutoSize = true };
        browser.Click += (_, _) => OpenDashboard();
        var hotspot = new Button { Text = "Start hotspot fallback", AutoSize = true };
        hotspot.Click += async (_, _) => _notice.Text = await _network.StartHotspotAsync(_ssid, _pass);
        var stopHotspot = new Button { Text = "Stop hotspot", AutoSize = true };
        stopHotspot.Click += async (_, _) => _notice.Text = await _network.StopHotspotAsync();

        var buttons = new FlowLayoutPanel { Dock = DockStyle.Top, AutoSize = true, Padding = new Padding(0, 8, 0, 8) };
        buttons.Controls.AddRange([add, browser, hotspot, stopHotspot]);

        var header = new FlowLayoutPanel { Dock = DockStyle.Top, FlowDirection = FlowDirection.TopDown, AutoSize = true, Padding = new Padding(12) };
        header.Controls.Add(new Label { Text = "FTPortal", AutoSize = true, Font = new Font("Segoe UI", 24, FontStyle.Bold) });
        header.Controls.Add(_address);
        header.Controls.Add(_transport);
        header.Controls.Add(new Label { Text = $"Hotspot fallback: SSID {_ssid} · password {_pass}", AutoSize = true });
        header.Controls.Add(_notice);
        header.Controls.Add(buttons);

        var panel = new Panel { Dock = DockStyle.Fill, Padding = new Padding(12) };
        panel.Controls.Add(_files);
        panel.Controls.Add(header);
        Controls.Add(panel);

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
        _timer.Tick += (_, _) => RefreshDashboard();
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
            if (_network.Snapshot().All(x => x.Priority >= 2))
                _notice.Text = await _network.StartHotspotAsync(_ssid, _pass);
        }
        catch (Exception ex) { _notice.Text = "Server failed: " + ex.Message; }
    }

    private void AddFile()
    {
        using var dialog = new OpenFileDialog { Multiselect = true, Title = "Select one-shot files" };
        if (dialog.ShowDialog(this) != DialogResult.OK) return;
        foreach (var path in dialog.FileNames) _shares.Add(path);
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
            _address.Text = $"http://{primary.Address}{suffix}    ·    http://ftphakan.local{suffix}";
            _transport.Text = $"Primary: {primary.Kind} ({primary.Adapter}) · fallback order: Wi-Fi → LAN → Hotspot";
        }
        var items = _shares.All().Select(x => $"{x.Name}  ·  {x.Size:N0} bytes  ·  one-shot").ToArray();
        _files.BeginUpdate(); _files.Items.Clear(); _files.Items.AddRange(items); _files.EndUpdate();
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
            _tray.ShowBalloonTip(2000, "FTPortal is still running", "Right-click the tray icon and choose Exit FTPortal to stop the host.", ToolTipIcon.Info);
        }
    }

    private void RestoreWindow() { Show(); WindowState = FormWindowState.Normal; Activate(); }

    private async Task ExitAsync()
    {
        _allowExit = true;
        _timer.Stop();
        if (_mdns is not null) await _mdns.DisposeAsync();
        await _server.DisposeAsync();
        _tray.Visible = false;
        Close();
    }
}
