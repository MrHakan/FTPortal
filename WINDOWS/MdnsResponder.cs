using System.Net;
using System.Net.Sockets;
using System.Text;

namespace FTPortal.Windows;

internal sealed class MdnsResponder : IAsyncDisposable
{
    private readonly Func<IPAddress?> _address;
    private readonly CancellationTokenSource _stop = new();
    private UdpClient? _udp;
    private Task? _loop;

    public MdnsResponder(Func<IPAddress?> address) => _address = address;

    public void Start()
    {
        try
        {
            _udp = new UdpClient(AddressFamily.InterNetwork);
            _udp.Client.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
            _udp.Client.Bind(new IPEndPoint(IPAddress.Any, 5353));
            _udp.JoinMulticastGroup(IPAddress.Parse("224.0.0.251"));
            _loop = Task.Run(RunAsync);
        }
        catch
        {
            _udp?.Dispose();
            _udp = null;
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
                var ip = _address();
                if (ip is null) continue;
                var response = BuildAResponse("ftphakan.local", ip);
                await _udp.SendAsync(response, new IPEndPoint(IPAddress.Parse("224.0.0.251"), 5353), _stop.Token);
            }
            catch (OperationCanceledException) { break; }
            catch { }
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
                var len = packet[offset++];
                if ((len & 0xC0) != 0 || offset + len > packet.Length) return false;
                labels.Add(Encoding.UTF8.GetString(packet, offset, len));
                offset += len;
            }
            offset++;
            if (offset + 4 > packet.Length) return false;
            var name = string.Join('.', labels);
            var type = (packet[offset] << 8) | packet[offset + 1];
            offset += 4;
            if (name.Equals(expected, StringComparison.OrdinalIgnoreCase) && (type == 1 || type == 255)) return true;
        }
        return false;
    }

    private static byte[] BuildAResponse(string name, IPAddress address)
    {
        using var ms = new MemoryStream();
        void U16(ushort n) { ms.WriteByte((byte)(n >> 8)); ms.WriteByte((byte)n); }
        void U32(uint n) { ms.WriteByte((byte)(n >> 24)); ms.WriteByte((byte)(n >> 16)); ms.WriteByte((byte)(n >> 8)); ms.WriteByte((byte)n); }
        U16(0); U16(0x8400); U16(0); U16(1); U16(0); U16(0);
        foreach (var label in name.Split('.'))
        {
            var bytes = Encoding.UTF8.GetBytes(label); ms.WriteByte((byte)bytes.Length); ms.Write(bytes);
        }
        ms.WriteByte(0); U16(1); U16(0x8001); U32(120); U16(4); ms.Write(address.GetAddressBytes());
        return ms.ToArray();
    }

    public async ValueTask DisposeAsync()
    {
        _stop.Cancel();
        _udp?.Dispose();
        if (_loop is not null) { try { await _loop; } catch { } }
        _stop.Dispose();
    }
}
