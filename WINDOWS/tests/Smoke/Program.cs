using System.Net;
using System.Net.Http.Headers;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using FTPortal.Windows;

internal static class Smoke
{
    [STAThread]
    private static int Main()
    {
        try
        {
            SelectionSurvivesRefresh();
            // ListBox installs a WinForms context; this console runner has no
            // message loop to resume the HTTP test's asynchronous continuations.
            SynchronizationContext.SetSynchronizationContext(null);
            RunAsync().GetAwaiter().GetResult();
            Console.WriteLine("Windows smoke passed: stable selections, streaming upload, limits, partial cleanup, cancellation, admission and one-shot lifecycle.");
            return 0;
        }
        catch (Exception error) { Console.Error.WriteLine(error); return 1; }
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    private static void SelectionSurvivesRefresh()
    {
        using var list = new ListBox { SelectionMode = SelectionMode.MultiExtended };
        MainForm.UpdateList(list, [], ["a", "b"], ["A", "B"]);
        list.SetSelected(1, true);
        MainForm.UpdateList(list, ["a", "b"], ["b", "c"], ["B updated", "C"]);
        Check(list.SelectedIndex == 0, "Selection must follow file identity when rows reorder.");
        MainForm.UpdateList(list, ["b", "c"], ["b", "c"], ["B updated", "C"]);
        Check(list.SelectedIndex == 0, "Unchanged refresh discarded selection.");
    }

    private static async Task RunAsync()
    {
        var root = Path.Combine(Path.GetTempPath(), "ftportal-smoke-" + Guid.NewGuid().ToString("N"));
        var received = Path.Combine(root, "received");
        Directory.CreateDirectory(received);
        try
        {
            using var network = new NetworkTransportManager();
            Check(network.IsAllowedClient(IPAddress.Loopback), "Loopback smoke client should be admitted.");
            Check(!network.IsAllowedClient(IPAddress.Parse("8.8.8.8")), "Public client was admitted.");
            var shares = new ShareRegistry(Path.Combine(root, "shares"));
            var transfers = new TransferCenter(Path.Combine(root, "history"));
            await using var host = new PortalServer(shares, transfers, network, received, browserUploadLimit: 32768);
            var listener = new TcpListener(IPAddress.Loopback, 0); listener.Start();
            var port = ((IPEndPoint)listener.LocalEndpoint).Port; listener.Stop();
            await host.StartAsync(port);
            using var client = new HttpClient { BaseAddress = new Uri($"http://127.0.0.1:{port}"), Timeout = TimeSpan.FromSeconds(15) };
            var page = await client.GetStringAsync("/dashboard");
            Check(page.Contains("Cancel queue") && page.Contains("Host &amp; connection"), "Packaged dashboard missing.");
            using var portal = JsonDocument.Parse(await client.GetStringAsync("/api/portal"));
            Check(portal.RootElement.GetProperty("maxUploadBytes").GetInt64() == 32768, "Advertised upload limit differs from enforcement.");

            async Task<HttpResponseMessage> UploadAsync(string name, byte[] bytes)
            {
                using var form = new MultipartFormDataContent();
                form.Add(new ByteArrayContent(bytes), "file", name);
                return await client.PostAsync("/upload", form);
            }
            var bytes = Encoding.UTF8.GetBytes("actual streamed file\n");
            using (var upload = await UploadAsync("receipt.txt", bytes))
                Check(upload.IsSuccessStatusCode, "Streaming upload failed: " + await upload.Content.ReadAsStringAsync());
            Check(File.ReadAllBytes(Path.Combine(received, "receipt.txt")).SequenceEqual(bytes), "Uploaded bytes changed.");
            using (var empty = await UploadAsync("empty.txt", [])) Check(empty.IsSuccessStatusCode, "Empty file was rejected.");
            using (var large = await UploadAsync("oversize.txt", new byte[32769])) Check(large.StatusCode == HttpStatusCode.RequestEntityTooLarge, "Oversize streaming body not rejected with 413.");
            Check(!File.Exists(Path.Combine(received, "oversize.txt")), "Oversize upload was published.");
            using (var form = new MultipartFormDataContent())
            {
                form.Add(new ByteArrayContent(bytes), "file", "first.txt"); form.Add(new ByteArrayContent(bytes), "file", "second.txt");
                using var multiple = await client.PostAsync("/upload", form);
                Check(multiple.StatusCode == HttpStatusCode.BadRequest, "Multiple files in one request must be rejected atomically.");
            }
            using (var broken = new StringContent("--broken\r\nContent-Disposition: form-data; name=\"file\"; filename=\"partial.txt\"\r\n\r\npartial bytes"))
            {
                broken.Headers.ContentType = MediaTypeHeaderValue.Parse("multipart/form-data; boundary=broken");
                using var result = await client.PostAsync("/upload", broken);
                Check(!result.IsSuccessStatusCode, "Truncated multipart upload reported success.");
            }
            Check(!File.Exists(Path.Combine(received, "partial.txt")) && !Directory.EnumerateFiles(received, "*.part").Any(), "A failed upload left partial files.");
            var simultaneous = await Task.WhenAll(UploadAsync("same.txt", bytes), UploadAsync("same.txt", bytes));
            foreach (var result in simultaneous) { using (result) Check(result.IsSuccessStatusCode, "Concurrent name collision lost a receipt."); }
            Check(Directory.EnumerateFiles(received, "same*.txt").Count() == 2, "Same-name uploads overwrote a receipt.");

            using (var gateBody = new GatedMultipart())
            {
                var request = client.PostAsync("/upload", gateBody);
                await WaitUntilAsync(() => transfers.Active().Any());
                var id = transfers.Active()[0].Id;
                Check(transfers.Cancel(id), "Could not cancel an active streaming upload.");
                gateBody.Release();
                using var response = await request;
                Check(!response.IsSuccessStatusCode, "Cancelled upload reported success.");
                Check(!File.Exists(Path.Combine(received, "cancelled.txt")), "Cancelled upload was published.");
            }
            Check(transfers.Active().Count == 0, "Active transfer state leaked after completion/cancellation.");
            Check(!Directory.EnumerateFiles(received, "*.part").Any(), "Cancellation left .part files.");
            var source = Path.Combine(root, "one-shot.txt"); File.WriteAllBytes(source, bytes);
            var share = shares.Add(source);
            Check(shares.Claim(share.Id) is not null, "Share claim failed.");
            using (var busy = await client.GetAsync("/download/" + share.Id)) Check(busy.StatusCode == HttpStatusCode.Gone, "Concurrent one-shot claim was admitted.");
            shares.Release(share.Id);
            using (var headRequest = new HttpRequestMessage(HttpMethod.Head, "/download/" + share.Id))
            using (var head = await client.SendAsync(headRequest))
                Check(head.IsSuccessStatusCode && shares.Available(share.Id) is not null, "HEAD consumed a one-shot share.");
            Check((await client.GetByteArrayAsync("/download/" + share.Id)).SequenceEqual(bytes), "One-shot download bytes changed.");
            await WaitUntilAsync(() => shares.Available(share.Id) is null);
            Check(File.Exists(source), "One-shot download deleted the source.");
            using (var consumed = await client.GetAsync("/download/" + share.Id)) Check(consumed.StatusCode == HttpStatusCode.Gone, "Consumed share stayed downloadable.");
            Check(transfers.History().Any(entry => !entry.Success), "Failed transfers missing from history.");
        }
        finally { try { Directory.Delete(root, recursive: true); } catch { } }
    }

    private static async Task WaitUntilAsync(Func<bool> condition)
    {
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        while (!condition()) await Task.Delay(20, deadline.Token);
    }

    private sealed class GatedMultipart : HttpContent
    {
        private readonly TaskCompletionSource _release = new(TaskCreationOptions.RunContinuationsAsynchronously);
        private static readonly byte[] Prefix = Encoding.UTF8.GetBytes("--gate\r\nContent-Disposition: form-data; name=\"file\"; filename=\"cancelled.txt\"\r\n\r\n");
        private static readonly byte[] Suffix = Encoding.UTF8.GetBytes("data\r\n--gate--\r\n");
        public GatedMultipart() { Headers.ContentType = MediaTypeHeaderValue.Parse("multipart/form-data; boundary=gate"); }
        public void Release() => _release.TrySetResult();
        protected override bool TryComputeLength(out long length) { length = Prefix.Length + Suffix.Length; return true; }
        protected override async Task SerializeToStreamAsync(Stream stream, TransportContext? context)
        {
            await stream.WriteAsync(Prefix); await stream.FlushAsync(); await _release.Task;
            await stream.WriteAsync(Suffix);
        }
    }
}
