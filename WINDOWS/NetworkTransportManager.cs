using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using Windows.Networking.Connectivity;
using Windows.Networking.NetworkOperators;

namespace FTPortal.Windows;

internal sealed record TransportAddress(
    string Kind,
    string Adapter,
    IPAddress Address,
    int Priority,
    IPAddress? SubnetMask = null,
    bool HasDefaultGateway = false,
    bool IsVirtual = false
);

/// <summary>
/// Reads the current Windows network topology and owns the Mobile Hotspot
/// fallback operation. The host is deliberately evaluated on every snapshot:
/// Wi-Fi, LAN and hotspot addresses can appear or disappear without restarting
/// the Kestrel listeners.
/// </summary>
internal sealed class NetworkTransportManager : IDisposable
{
    private static readonly string[] IgnoredAdapterMarkers =
    [
        "vpn",
        "tap-windows",
        "wintun",
        "wireguard",
        "tailscale",
        "zerotier",
        "hamachi",
        "hyper-v",
        "vmware",
        "virtualbox",
        "docker",
        "wsl"
    ];

    public event EventHandler? NetworkChanged;

    public NetworkTransportManager()
    {
        NetworkChange.NetworkAddressChanged += OnNetworkChanged;
        NetworkChange.NetworkAvailabilityChanged += OnNetworkChanged;
    }

    public IReadOnlyList<TransportAddress> Snapshot()
    {
        var result = new List<TransportAddress>();

        NetworkInterface[] interfaces;
        try
        {
            interfaces = NetworkInterface.GetAllNetworkInterfaces();
        }
        catch
        {
            return [];
        }

        foreach (var nic in interfaces)
        {
            try
            {
                if (nic.OperationalStatus != OperationalStatus.Up ||
                    nic.NetworkInterfaceType == NetworkInterfaceType.Loopback)
                    continue;

                var (kind, priority) = Classify(nic);
                if (kind == "Ignored") continue;

                var properties = nic.GetIPProperties();
                var hasGateway = properties.GatewayAddresses.Any(gateway =>
                    gateway.Address.AddressFamily == AddressFamily.InterNetwork &&
                    !IPAddress.IsLoopback(gateway.Address));

                foreach (var unicast in properties.UnicastAddresses)
                {
                    var address = unicast.Address;
                    if (!IsUsablePrivateIpv4(address)) continue;

                    result.Add(new TransportAddress(
                        kind,
                        nic.Name,
                        address,
                        priority,
                        unicast.IPv4Mask,
                        hasGateway,
                        kind == "Hotspot" || NameContainsVirtual(nic)
                    ));
                }
            }
            catch
            {
                // An adapter can disappear between enumeration and property
                // access. Keep the other active bearers usable.
            }
        }

        return result
            .OrderBy(address => address.Priority)
            .ThenByDescending(address => address.HasDefaultGateway)
            .ThenBy(address => address.Adapter, StringComparer.OrdinalIgnoreCase)
            .ThenBy(address => address.Address.ToString(), StringComparer.Ordinal)
            .ToArray();
    }

    public TransportAddress? Primary() => Snapshot().FirstOrDefault();

    /// <summary>
    /// Limits browser and peer HTTP requests to loopback or a subnet currently
    /// represented by an operational, private local adapter. This is the native
    /// Windows equivalent of the PowerShell active-bearer admission check.
    /// </summary>
    public bool IsAllowedClient(IPAddress? clientAddress)
    {
        if (clientAddress is null) return false;
        if (clientAddress.IsIPv4MappedToIPv6) clientAddress = clientAddress.MapToIPv4();
        if (IPAddress.IsLoopback(clientAddress)) return true;
        if (!IsUsablePrivateIpv4(clientAddress)) return false;

        return Snapshot().Any(local =>
            (local.Kind == "Hotspot" || !local.IsVirtual) &&
            local.SubnetMask is not null &&
            SameSubnet(local.Address, clientAddress, local.SubnetMask));
    }

    /// <summary>
    /// Selects the local address that can answer a client on a particular
    /// subnet. This prevents mDNS from advertising a Wi-Fi address to a
    /// hotspot-only client when both bearers happen to be up.
    /// </summary>
    public IPAddress? AddressForClient(IPAddress? clientAddress)
    {
        if (clientAddress?.IsIPv4MappedToIPv6 == true) clientAddress = clientAddress.MapToIPv4();
        var transports = Snapshot();
        if (clientAddress is not null && IsUsablePrivateIpv4(clientAddress))
        {
            var matching = transports.FirstOrDefault(local =>
                (local.Kind == "Hotspot" || !local.IsVirtual) &&
                local.SubnetMask is not null &&
                SameSubnet(local.Address, clientAddress, local.SubnetMask));
            if (matching is not null) return matching.Address;
        }
        return clientAddress is null || IPAddress.IsLoopback(clientAddress)
            ? transports.FirstOrDefault()?.Address
            : null;
    }

    public async Task<string> StartHotspotAsync(string ssid, string passphrase)
    {
        try
        {
            var profile = GetTetheringProfile();
            if (profile is null) return "No Windows connection profile is available for Mobile Hotspot.";

            var manager = NetworkOperatorTetheringManager.CreateFromConnectionProfile(profile);
            var configuration = new NetworkOperatorTetheringAccessPointConfiguration
            {
                Ssid = ssid,
                Passphrase = passphrase
            };
            await manager.ConfigureAccessPointAsync(configuration);
            var result = await manager.StartTetheringAsync();
            return $"Mobile Hotspot: {result.Status}";
        }
        catch (Exception ex)
        {
            return "Mobile Hotspot unavailable: " + ShortError(ex);
        }
    }

    public async Task<string> StopHotspotAsync()
    {
        try
        {
            var profile = GetTetheringProfile();
            if (profile is null) return "No Windows connection profile is available.";

            var manager = NetworkOperatorTetheringManager.CreateFromConnectionProfile(profile);
            var result = await manager.StopTetheringAsync();
            return $"Mobile Hotspot: {result.Status}";
        }
        catch (Exception ex)
        {
            return "Could not stop Mobile Hotspot: " + ShortError(ex);
        }
    }

    public void Dispose()
    {
        NetworkChange.NetworkAddressChanged -= OnNetworkChanged;
        NetworkChange.NetworkAvailabilityChanged -= OnNetworkChanged;
    }

    private static ConnectionProfile? GetTetheringProfile()
    {
        return NetworkInformation.GetInternetConnectionProfile()
            ?? NetworkInformation.GetConnectionProfiles()
                .FirstOrDefault(profile => profile.NetworkAdapter is not null);
    }

    private void OnNetworkChanged(object? sender, EventArgs args) => NetworkChanged?.Invoke(this, args);

    private static (string Kind, int Priority) Classify(NetworkInterface nic)
    {
        var name = (nic.Name + " " + nic.Description).ToLowerInvariant();
        if (IgnoredAdapterMarkers.Any(name.Contains) || nic.NetworkInterfaceType == NetworkInterfaceType.Tunnel)
            return ("Ignored", 99);

        if (name.Contains("local area connection*") ||
            name.Contains("mobile hotspot") ||
            name.Contains("wi-fi direct") ||
            name.Contains("wifi direct"))
            return ("Hotspot", 2);

        if (nic.NetworkInterfaceType == NetworkInterfaceType.Wireless80211)
            return ("Wi-Fi", 0);

        if (nic.NetworkInterfaceType is
            NetworkInterfaceType.Ethernet or
            NetworkInterfaceType.GigabitEthernet or
            NetworkInterfaceType.FastEthernetFx or
            NetworkInterfaceType.FastEthernetT)
            return ("LAN", 1);

        return ("Other", 3);
    }

    private static bool NameContainsVirtual(NetworkInterface nic)
    {
        var name = (nic.Name + " " + nic.Description).ToLowerInvariant();
        return name.Contains("virtual") || name.Contains("hyper-v") || name.Contains("vmware");
    }

    private static bool IsUsablePrivateIpv4(IPAddress address)
    {
        if (address.AddressFamily != AddressFamily.InterNetwork || IPAddress.IsLoopback(address)) return false;
        var bytes = address.GetAddressBytes();
        if (bytes[0] == 169 && bytes[1] == 254) return false; // APIPA is not a stable transport.
        return bytes[0] == 10 ||
            (bytes[0] == 172 && bytes[1] is >= 16 and <= 31) ||
            (bytes[0] == 192 && bytes[1] == 168);
    }

    private static bool SameSubnet(IPAddress left, IPAddress right, IPAddress mask)
    {
        var leftBytes = left.GetAddressBytes();
        var rightBytes = right.GetAddressBytes();
        var maskBytes = mask.GetAddressBytes();
        if (leftBytes.Length != 4 || rightBytes.Length != 4 || maskBytes.Length != 4) return false;

        for (var index = 0; index < 4; index++)
        {
            if ((leftBytes[index] & maskBytes[index]) != (rightBytes[index] & maskBytes[index])) return false;
        }
        return true;
    }

    private static string ShortError(Exception error) =>
        string.IsNullOrWhiteSpace(error.Message) ? error.GetType().Name : error.Message;
}
