using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using Windows.Networking.Connectivity;
using Windows.Networking.NetworkOperators;

namespace FTPortal.Windows;

internal sealed record TransportAddress(string Kind, string Adapter, IPAddress Address, int Priority);

internal sealed class NetworkTransportManager
{
    public IReadOnlyList<TransportAddress> Snapshot()
    {
        var result = new List<TransportAddress>();
        foreach (var nic in NetworkInterface.GetAllNetworkInterfaces())
        {
            if (nic.OperationalStatus != OperationalStatus.Up || nic.NetworkInterfaceType == NetworkInterfaceType.Loopback) continue;
            foreach (var unicast in nic.GetIPProperties().UnicastAddresses)
            {
                if (unicast.Address.AddressFamily != AddressFamily.InterNetwork || IPAddress.IsLoopback(unicast.Address)) continue;
                var (kind, priority) = Classify(nic);
                result.Add(new TransportAddress(kind, nic.Name, unicast.Address, priority));
            }
        }
        return result.OrderBy(x => x.Priority).ThenBy(x => x.Adapter).ToArray();
    }

    public TransportAddress? Primary() => Snapshot().FirstOrDefault();

    public async Task<string> StartHotspotAsync(string ssid, string passphrase)
    {
        try
        {
            var profile = NetworkInformation.GetInternetConnectionProfile()
                ?? NetworkInformation.GetConnectionProfiles().FirstOrDefault(p => p.NetworkAdapter is not null);
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
            return "Mobile Hotspot unavailable: " + ex.Message;
        }
    }

    public async Task<string> StopHotspotAsync()
    {
        try
        {
            var profile = NetworkInformation.GetInternetConnectionProfile()
                ?? NetworkInformation.GetConnectionProfiles().FirstOrDefault(p => p.NetworkAdapter is not null);
            if (profile is null) return "No Windows connection profile is available.";
            var manager = NetworkOperatorTetheringManager.CreateFromConnectionProfile(profile);
            var result = await manager.StopTetheringAsync();
            return $"Mobile Hotspot: {result.Status}";
        }
        catch (Exception ex)
        {
            return "Could not stop Mobile Hotspot: " + ex.Message;
        }
    }

    private static (string Kind, int Priority) Classify(NetworkInterface nic)
    {
        var name = (nic.Name + " " + nic.Description).ToLowerInvariant();
        if (name.Contains("local area connection*") || name.Contains("mobile hotspot") || name.Contains("wi-fi direct") || name.Contains("virtual"))
            return ("Hotspot", 2);
        if (nic.NetworkInterfaceType == NetworkInterfaceType.Wireless80211)
            return ("Wi-Fi", 0);
        if (nic.NetworkInterfaceType is NetworkInterfaceType.Ethernet or NetworkInterfaceType.GigabitEthernet or NetworkInterfaceType.FastEthernetFx or NetworkInterfaceType.FastEthernetT)
            return ("LAN", 1);
        return ("Other", 3);
    }
}
