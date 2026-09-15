using System.Net;
using System.Net.Sockets;
using System.Text;

namespace FTPortal.Windows;

internal sealed class MdnsResponder : IAsyncDisposable
{
    private static readonly IPAddress MulticastAddress = IPAddress.Parse("224.0.0.251");
    private readonly Func<IPAddress?, IPAddress?> _address;
    private readonly CancellationTokenSource _stop = new();
    private UdpClient? _udp;
    private Task? _loop;

    public bool IsRunning => _udp is not null && _loop is not null && !_loop.IsCompleted;
    public string? LastError { get; private set; }

    public MdnsResponder(Func<IPAddress?> address) : this(_ => address()) { }

    public MdnsResponder(Func<IPAddress?, IPAddress?> address) => _address = address;

    public void Start()
    {
        if (_udp is not null) return;
        try
        {
            var udp = new UdpClient(AddressFamily.InterNetwork);
            udp.Client.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
            udp.Client.Bind(new IPEndPoint(IPAddress.Any, 5353));
            var joined = false;
            foreach (var nic in System.Net.NetworkInformation.NetworkInterface.GetAllNetworkInterfaces())
            {
                try
                {
                    if (nic.OperationalStatus != System.Net.NetworkInformation.OperationalStatus.Up) continue;
                    foreach (var unicast in nic.GetIPProperties().UnicastAddresses)
                    {
                        if (unicast.Address.AddressFamily != AddressFamily.InterNetwork) continue;
                        try
                        {
                            udp.JoinMulticastGroup(MulticastAddress, unicast.Address);
                            joined = true;
                        }
                        catch (SocketException) { }
                    }
                }
                catch
                {
                    // An adapter may disappear while mDNS is joining groups.
                }
            }
            if (!joined) udp.JoinMulticastGroup(MulticastAddress);
            _udp = udp;
            LastError = null;
            _loop = Task.Run(RunAsync);
        }
        catch (Exception ex)
        {
            LastError = ex.Message;
            _udp?.Dispose();
            _udp = null;
            _loop = null;
        }
    }

    private async Task RunAsync()
    {
        if (_udp is null) return;
        while (!_stop.IsCancellationRequested)
        {
            try
            {
                var result = await _udp.ReceiveAsync(_stop.Token);
                if (!ContainsQuestion(result.Buffer, "ftphakan.local")) continue;
                var ip = _address(result.RemoteEndPoint.Address);
                if (ip is null || ip.AddressFamily != AddressFamily.InterNetwork) continue;
                var transactionId = result.Buffer.Length >= 2
                    ? (ushort)((result.Buffer[0] << 8) | result.Buffer[1])
                    : (ushort)0;
                var response = BuildAResponse("ftphakan.local", ip, transactionId);
                await _udp.SendAsync(response, result.RemoteEndPoint, _stop.Token);
                LastError = null;
            }
            catch (OperationCanceledException)
            {
                break;
            }
            catch (ObjectDisposedException) when (_stop.IsCancellationRequested)
            {
                break;
            }
            catch (Exception ex)
            {
                LastError = ex.Message;
                try { await Task.Delay(250, _stop.Token); }
                catch (OperationCanceledException) { break; }
            }
        }
    }

    private static bool ContainsQuestion(byte[] packet, string expected)
    {
        if (packet.Length < 12) return false;
        var count = (packet[4] << 8) | packet[5];
        var offset = 12;
        for (var i = 0; i < count && offset < packet.Length; i++)
        {
            var labels = new List<string>();
            while (offset < packet.Length && packet[offset] != 0)
            {
                var length = packet[offset++];
                if ((length & 0xC0) != 0 || length == 0 || offset + length > packet.Length) return false;
                labels.Add(Encoding.UTF8.GetString(packet, offset, length));
                offset += length;
            }
            if (offset >= packet.Length) return false;
            offset++;
            if (offset + 4 > packet.Length) return false;
            var name = string.Join('.', labels);
            var type = (packet[offset] << 8) | packet[offset + 1];
            offset += 4;
            if (name.Equals(expected, StringComparison.OrdinalIgnoreCase) && (type == 1 || type == 255)) return true;
        }
        return false;
    }

    private static byte[] BuildAResponse(string name, IPAddress address, ushort transactionId)
    {
        using var stream = new MemoryStream();
        void U16(ushort value)
        {
            stream.WriteByte((byte)(value >> 8));
            stream.WriteByte((byte)value);
        }
        void U32(uint value)
        {
            stream.WriteByte((byte)(value >> 24));
            stream.WriteByte((byte)(value >> 16));
            stream.WriteByte((byte)(value >> 8));
            stream.WriteByte((byte)value);
        }

        U16(transactionId);
        U16(0x8400);
        U16(0);
        U16(1);
        U16(0);
        U16(0);
        foreach (var label in name.Split('.'))
        {
            var bytes = Encoding.UTF8.GetBytes(label);
            stream.WriteByte((byte)bytes.Length);
            stream.Write(bytes);
        }
        stream.WriteByte(0);
        U16(1);
        U16(0x8001);
        U32(120);
        U16(4);
        stream.Write(address.GetAddressBytes());
        return stream.ToArray();
    }

    public async ValueTask DisposeAsync()
    {
        _stop.Cancel();
        _udp?.Dispose();
        if (_loop is not null)
        {
            try { await _loop; }
            catch (OperationCanceledException) { }
        }
        _udp = null;
        _loop = null;
        _stop.Dispose();
    }
}
