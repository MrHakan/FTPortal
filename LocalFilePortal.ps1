# ==============================================================================
#  LocalFilePortal.ps1  v2.0
#  Single-file PowerShell local file transfer portal
#   - Wi-Fi only, no admin required (TcpListener)
#   - Connected devices visible, click-to-target + public broadcast
#   - No time limit, no size limit
#   - Streaming multipart parser + C# FastScan boundary -> fast upload
#   - Native PowerShell 5.1+, no external dependencies
# ==============================================================================

Add-Type -AssemblyName System.Web
Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

# ============================== SETTINGS ======================================
$Global:Password    = 'hako123'
$Global:Port        = 8080
$Global:ShareFolder = 'C:\SharedTransfer'
$Global:MetaFolder  = Join-Path $Global:ShareFolder '.meta'
$Global:CookieName  = 'LDSID'
$Global:SessionTTL  = [TimeSpan]::FromDays(365)     # effectively no expiry
$Global:DeviceTTL   = [TimeSpan]::FromMinutes(5)    # 'online' threshold
$Global:MaxThreads  = 32
$Global:SweepEvery  = [TimeSpan]::FromMinutes(2)

$Global:Sessions   = [hashtable]::Synchronized(@{})   # sid -> @{Sid;PubId;Nick;IP;UA;Created;LastSeen}
$Global:PubIndex   = [hashtable]::Synchronized(@{})   # pubId -> sid
$Global:Transfers  = [hashtable]::Synchronized(@{})   # id -> @{Id;Name;Path;Size;Sender;SenderNick;Target;Created}
$Global:UploadLock = New-Object object
$Global:SweepState = [hashtable]::Synchronized(@{ Last = [datetime]::MinValue })

foreach ($d in @($Global:ShareFolder, $Global:MetaFolder)) {
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

# =================== FAST BOUNDARY SCANNER (C#) ===============================
# PowerShell array index access is slow. C# native scan -> ~100x faster.
if (-not ('LFP.FastScan' -as [type])) {
    Add-Type -TypeDefinition @'
namespace LFP {
    public static class FastScan {
        public static int IndexOf(byte[] hay, int start, int len, byte[] needle) {
            int nlen = needle.Length;
            if (nlen == 0 || len < nlen) return -1;
            int end = start + len - nlen;
            byte n0 = needle[0];
            for (int i = start; i <= end; i++) {
                if (hay[i] != n0) continue;
                int j = 1;
                while (j < nlen && hay[i+j] == needle[j]) j++;
                if (j == nlen) return i;
            }
            return -1;
        }
    }
}
'@
}

# ============================== HELPERS =======================================
function Get-IconForFile {
    param([string]$Name)
    $ext = [System.IO.Path]::GetExtension($Name).ToLowerInvariant().TrimStart('.')
    switch ($ext) {
        'pdf'                                   { return [char]0xD83D + [char]0xDCC4 }
        { $_ -in 'zip','rar','7z','tar','gz' }  { return [char]0xD83D + [char]0xDDDC }
        { $_ -in 'jpg','jpeg','png','gif','bmp','webp','svg','tiff' } { return [char]0xD83D + [char]0xDDBC }
        { $_ -in 'mp4','mkv','avi','mov','wmv','flv','webm' }         { return [char]0xD83C + [char]0xDFAC }
        { $_ -in 'mp3','wav','flac','aac','ogg','m4a' }              { return [char]0xD83C + [char]0xDFB5 }
        { $_ -in 'exe','msi','bat','cmd','ps1' }                     { return [char]0x2699 + [char]0xFE0F }
        { $_ -in 'doc','docx' }                 { return [char]0xD83D + [char]0xDCDD }
        { $_ -in 'xls','xlsx','csv' }           { return [char]0xD83D + [char]0xDCCA }
        { $_ -in 'ppt','pptx' }                 { return [char]0xD83D + [char]0xDCFD }
        { $_ -in 'txt','log','md','ini','cfg' } { return [char]0xD83D + [char]0xDCC3 }
        { $_ -in 'html','htm','css','js','json','xml' } { return [char]0xD83C + [char]0xDF10 }
        default                                 { return [char]0xD83D + [char]0xDCC1 }
    }
}

function Format-Size {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N2} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N2} KB' -f ($Bytes / 1KB)) }
    return ('{0} B' -f [int]$Bytes)
}

function New-SessionId {
    $bytes = New-Object byte[] 32
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return ([System.BitConverter]::ToString($bytes) -replace '-', '').ToLowerInvariant()
}

function New-ShortId {
    param([int]$Bytes = 4)
    $b = New-Object byte[] $Bytes
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($b) } finally { $rng.Dispose() }
    return ([System.BitConverter]::ToString($b) -replace '-','').ToLowerInvariant()
}

function Get-DeviceLabel {
    param([string]$UA, [string]$IP)
    $ua = if ($UA) { $UA.ToLowerInvariant() } else { '' }
    $os = 'Device'
    if     ($ua -match 'windows nt')       { $os = 'Windows' }
    elseif ($ua -match 'iphone')           { $os = 'iPhone' }
    elseif ($ua -match 'ipad')             { $os = 'iPad' }
    elseif ($ua -match 'android')          { $os = 'Android' }
    elseif ($ua -match 'macintosh|mac os') { $os = 'Mac' }
    elseif ($ua -match 'linux')            { $os = 'Linux' }
    $last = if ($IP -match '\.(\d+)$') { $Matches[1] } else { 'x' }
    return "$os-$last"
}

function Invoke-PeriodicSweep {
    $now = Get-Date
    [System.Threading.Monitor]::Enter($Global:SweepState)
    try {
        if (($now - $Global:SweepState.Last) -lt $Global:SweepEvery) { return }
        $Global:SweepState.Last = $now
    } finally { [System.Threading.Monitor]::Exit($Global:SweepState) }

    $dead = @()
    foreach ($k in @($Global:Sessions.Keys)) {
        $s = $Global:Sessions[$k]
        if ($null -eq $s -or ($now - $s.LastSeen) -gt $Global:SessionTTL) { $dead += $k }
    }
    foreach ($k in $dead) {
        $s = $Global:Sessions[$k]
        if ($s -and $s.PubId) { [void]$Global:PubIndex.Remove($s.PubId) }
        [void]$Global:Sessions.Remove($k)
    }
}

function ConvertTo-SafeRelPath {
    # Sanitize a client-supplied filename: keep slashes for folder structure,
    # drop path traversal, drop invalid path chars per segment, strip leading /.
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    $p = $Path -replace '\\', '/'
    $p = $p.TrimStart('/')
    $invalid = [System.IO.Path]::GetInvalidFileNameChars()
    $segs = $p.Split('/')
    $clean = New-Object System.Collections.Generic.List[string]
    foreach ($s in $segs) {
        $s = $s.Trim()
        if ([string]::IsNullOrEmpty($s)) { continue }
        if ($s -eq '.' -or $s -eq '..') { continue }
        foreach ($ch in $invalid) { $s = $s.Replace($ch, '_') }
        if ($s) { [void]$clean.Add($s) }
    }
    return ($clean -join '/')
}

function Save-TransferMeta {
    param($T)
    $obj = [ordered]@{
        id         = $T.Id
        name       = $T.Name
        path       = $T.Path
        size       = $T.Size
        sender     = $T.Sender
        senderNick = $T.SenderNick
        target     = $T.Target
        bundle     = $T.BundleId
        created    = $T.Created.ToString('o')
    }
    $json = $obj | ConvertTo-Json -Compress
    [System.IO.File]::WriteAllText((Join-Path $Global:MetaFolder ($T.Id + '.json')), $json, [System.Text.Encoding]::UTF8)
}

function Import-AllTransfers {
    if (-not (Test-Path -LiteralPath $Global:MetaFolder)) { return }
    Get-ChildItem -LiteralPath $Global:MetaFolder -File -Filter '*.json' -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            $raw = Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8
            $j   = $raw | ConvertFrom-Json
            if (Test-Path -LiteralPath $j.path -PathType Leaf) {
                $Global:Transfers[$j.id] = @{
                    Id=$j.id; Name=$j.name; Path=$j.path; Size=[int64]$j.size
                    Sender=$j.sender; SenderNick=$j.senderNick; Target=$j.target
                    BundleId=$j.bundle
                    Created=[DateTime]::Parse($j.created)
                }
            } else {
                Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
            }
        } catch {}
    }
}

function Remove-Transfer {
    param([string]$Id)
    $t = $Global:Transfers[$Id]
    if ($null -eq $t) { return $false }
    try { Remove-Item -LiteralPath $t.Path -Force -ErrorAction SilentlyContinue } catch {}
    try { Remove-Item -LiteralPath (Join-Path $Global:MetaFolder ($Id + '.json')) -Force -ErrorAction SilentlyContinue } catch {}
    [void]$Global:Transfers.Remove($Id)
    return $true
}

# ============================== HTTP LAYER ====================================
function Read-HttpRequest {
    param([System.IO.Stream]$Stream)
    $headerBytes = New-Object System.Collections.Generic.List[byte]
    $b0=-1;$b1=-1;$b2=-1;$b3=-1
    while ($true) {
        $b = $Stream.ReadByte()
        if ($b -lt 0) { break }
        $headerBytes.Add([byte]$b)
        $b0=$b1; $b1=$b2; $b2=$b3; $b3=$b
        if ($b0 -eq 13 -and $b1 -eq 10 -and $b2 -eq 13 -and $b3 -eq 10) { break }
        if ($headerBytes.Count -gt 65536) { break }
    }
    if ($headerBytes.Count -eq 0) { return $null }

    $latin1 = [System.Text.Encoding]::GetEncoding(28591)
    $headerText = $latin1.GetString($headerBytes.ToArray())
    $lines = $headerText -split "`r`n"
    if ($lines.Count -lt 1 -or [string]::IsNullOrWhiteSpace($lines[0])) { return $null }

    $reqParts = $lines[0].Split(' ')
    if ($reqParts.Count -lt 2) { return $null }
    $method    = $reqParts[0].ToUpperInvariant()
    $rawTarget = $reqParts[1]

    $path = $rawTarget; $query = ''
    $qi = $rawTarget.IndexOf('?')
    if ($qi -ge 0) { $path = $rawTarget.Substring(0,$qi); $query = $rawTarget.Substring($qi+1) }

    $headers = @{}
    for ($i=1; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ([string]::IsNullOrEmpty($line)) { break }
        $ci = $line.IndexOf(':')
        if ($ci -gt 0) {
            $hn = $line.Substring(0,$ci).Trim().ToLowerInvariant()
            $hv = $line.Substring($ci+1).Trim()
            $headers[$hn] = $hv
        }
    }

    $cookies = @{}
    if ($headers.ContainsKey('cookie')) {
        foreach ($pair in $headers['cookie'].Split(';')) {
            $kv = $pair.Trim(); $ei = $kv.IndexOf('=')
            if ($ei -gt 0) { $cookies[$kv.Substring(0,$ei).Trim()] = $kv.Substring($ei+1).Trim() }
        }
    }

    $contentLength = 0
    if ($headers.ContainsKey('content-length')) { [void][int64]::TryParse($headers['content-length'], [ref]$contentLength) }
    $contentType = ''
    if ($headers.ContainsKey('content-type')) { $contentType = $headers['content-type'] }
    $userAgent = ''
    if ($headers.ContainsKey('user-agent')) { $userAgent = $headers['user-agent'] }

    return [pscustomobject]@{
        Method=$method; Path=$path.ToLowerInvariant(); RawTarget=$rawTarget; Query=$query
        Headers=$headers; Cookies=$cookies; ContentLength=$contentLength; ContentType=$contentType
        UserAgent=$userAgent; Stream=$Stream; Body=$null; ClientIp='?'
    }
}

function Read-RequestBody {
    param([System.IO.Stream]$Stream, [int64]$Length, [int64]$Cap = 4194304)
    if ($Length -le 0) { return New-Object byte[] 0 }
    $effective = [int][Math]::Min($Length, $Cap)
    $buf = New-Object byte[] $effective
    $got = 0
    while ($got -lt $effective) {
        $r = $Stream.Read($buf, $got, [int][Math]::Min(81920, $effective - $got))
        if ($r -le 0) { break }
        $got += $r
    }
    if ($got -lt $effective) {
        $trim = New-Object byte[] $got
        [System.Array]::Copy($buf, 0, $trim, 0, $got)
        return $trim
    }
    return $buf
}

function Get-HttpStatusText {
    param([int]$Code)
    switch ($Code) {
        200 { 'OK' } 204 { 'No Content' } 302 { 'Found' } 400 { 'Bad Request' }
        401 { 'Unauthorized' } 403 { 'Forbidden' } 404 { 'Not Found' }
        405 { 'Method Not Allowed' } 500 { 'Internal Server Error' } default { 'OK' }
    }
}

function Send-Response {
    param(
        [System.IO.Stream]$Stream, [int]$Status = 200,
        [string]$ContentType = 'text/html; charset=utf-8',
        [byte[]]$Body = $null, [hashtable]$ExtraHeaders = $null
    )
    if ($null -eq $Body) { $Body = New-Object byte[] 0 }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("HTTP/1.1 $Status " + (Get-HttpStatusText $Status) + "`r`n")
    [void]$sb.Append("Content-Type: $ContentType`r`n")
    [void]$sb.Append("Content-Length: $($Body.Length)`r`n")
    [void]$sb.Append("Cache-Control: no-store`r`n")
    [void]$sb.Append("Connection: close`r`n")
    if ($ExtraHeaders) {
        foreach ($k in $ExtraHeaders.Keys) { [void]$sb.Append("$k`: $($ExtraHeaders[$k])`r`n") }
    }
    [void]$sb.Append("`r`n")
    $headBytes = [System.Text.Encoding]::GetEncoding(28591).GetBytes($sb.ToString())
    $Stream.Write($headBytes, 0, $headBytes.Length)
    if ($Body.Length -gt 0) { $Stream.Write($Body, 0, $Body.Length) }
    $Stream.Flush()
}

function Send-HtmlResponse {
    param([System.IO.Stream]$Stream, [string]$Html, [int]$Status = 200, [hashtable]$ExtraHeaders = $null)
    Send-Response -Stream $Stream -Status $Status -ContentType 'text/html; charset=utf-8' -Body ([System.Text.Encoding]::UTF8.GetBytes($Html)) -ExtraHeaders $ExtraHeaders
}

function Send-JsonResponse {
    param([System.IO.Stream]$Stream, [string]$Json, [int]$Status = 200, [hashtable]$ExtraHeaders = $null)
    Send-Response -Stream $Stream -Status $Status -ContentType 'application/json; charset=utf-8' -Body ([System.Text.Encoding]::UTF8.GetBytes($Json)) -ExtraHeaders $ExtraHeaders
}

function Send-RedirectResponse {
    param([System.IO.Stream]$Stream, [string]$Location, [hashtable]$ExtraHeaders = $null)
    $h = @{ 'Location' = $Location }
    if ($ExtraHeaders) { foreach ($k in $ExtraHeaders.Keys) { $h[$k] = $ExtraHeaders[$k] } }
    Send-Response -Stream $Stream -Status 302 -ContentType 'text/html; charset=utf-8' -Body (New-Object byte[] 0) -ExtraHeaders $h
}

function New-SessionCookieHeader {
    param([string]$Sid, [bool]$Expire = $false)
    if ($Expire) {
        return "$Global:CookieName=deleted; Path=/; HttpOnly; SameSite=Strict; Expires=Thu, 01 Jan 1970 00:00:00 GMT"
    }
    $exp = (Get-Date).Add($Global:SessionTTL).ToUniversalTime().ToString('R')
    return "$Global:CookieName=$Sid; Path=/; HttpOnly; SameSite=Strict; Expires=$exp"
}

function Test-ValidSession {
    param($Req)
    $sid = $Req.Cookies[$Global:CookieName]
    if ($sid -and $Global:Sessions.ContainsKey($sid)) {
        $Global:Sessions[$sid].LastSeen = Get-Date
        return $sid
    }
    return $null
}

function Resolve-TargetSid {
    param([string]$TargetParam)
    if ([string]::IsNullOrWhiteSpace($TargetParam) -or $TargetParam -eq 'public') { return 'public' }
    if ($Global:PubIndex.ContainsKey($TargetParam)) { return $Global:PubIndex[$TargetParam] }
    return $null
}

function Get-MultipartField {
    # Small multipart field reader (nick/id). Large files go through Save-UploadedFileStream.
    param([byte[]]$BodyBytes, [string]$ContentType, [string]$FieldName)
    if (-not $BodyBytes -or $BodyBytes.Length -eq 0) { return $null }
    if ($ContentType -notmatch 'boundary=(.+)$') { return $null }
    $boundary = $Matches[1].Trim().Trim('"')
    $latin1 = [System.Text.Encoding]::GetEncoding(28591)
    $text = $latin1.GetString($BodyBytes)
    $parts = $text -split [regex]::Escape('--' + $boundary)
    foreach ($p in $parts) {
        if ($p -match ('name="' + [regex]::Escape($FieldName) + '"')) {
            $idx = $p.IndexOf("`r`n`r`n")
            if ($idx -ge 0) {
                $val = $p.Substring($idx + 4)
                if ($val.EndsWith("`r`n")) { $val = $val.Substring(0, $val.Length - 2) }
                $bytes = $latin1.GetBytes($val)
                return [System.Text.Encoding]::UTF8.GetString($bytes)
            }
        }
    }
    return $null
}

# ===================== MULTIPART STREAMING PARSER =============================
function Save-UploadedFileStream {
    # Streams the network directly to disk in 256KB chunks. C# FastScan for boundary.
    # Single shared buffer (chunkSize + delimLen) keeps allocations minimal.
    param(
        [System.IO.Stream]$NetStream, [string]$ContentType,
        [string]$SenderSid, [string]$Target, [string]$BundleId
    )

    if ($ContentType -notmatch 'boundary=(.+)$') { return @{ ok=$false; status=400; msg='Boundary not found' } }
    $boundary = $Matches[1].Trim().Trim('"')
    $latin1   = [System.Text.Encoding]::GetEncoding(28591)

    # Read multipart part headers
    $hdrBuf = New-Object System.Collections.Generic.List[byte]
    $b0=-1;$b1=-1;$b2=-1;$b3=-1
    while ($true) {
        $b = $NetStream.ReadByte()
        if ($b -lt 0) { return @{ ok=$false; status=400; msg='Connection closed (header)' } }
        $hdrBuf.Add([byte]$b)
        $b0=$b1; $b1=$b2; $b2=$b3; $b3=$b
        if ($b0 -eq 13 -and $b1 -eq 10 -and $b2 -eq 13 -and $b3 -eq 10) { break }
        if ($hdrBuf.Count -gt 8192) { return @{ ok=$false; status=400; msg='Multipart header too large' } }
    }
    $hdrText  = $latin1.GetString($hdrBuf.ToArray())
    $rawName  = $null
    if ($hdrText -match 'filename="([^"]*)"') { $rawName = $Matches[1] }
    if ([string]::IsNullOrWhiteSpace($rawName)) { return @{ ok=$false; status=400; msg='No filename' } }
    # Filename may be UTF-8; re-decode the latin1 bytes
    $fnBytes = $latin1.GetBytes($rawName)
    try { $rawName = [System.Text.Encoding]::UTF8.GetString($fnBytes) } catch {}
    # Preserve relative path for display / ZIP folder tree; use basename for disk.
    $relPath  = ConvertTo-SafeRelPath -Path $rawName
    if ([string]::IsNullOrWhiteSpace($relPath)) { return @{ ok=$false; status=400; msg='Invalid filename' } }
    $fileName = ($relPath.Split('/'))[-1]

    # Reserve unique file path
    # NOTE: local variable is $targetPath - PowerShell is case-insensitive so using
    # $target would collide with the $Target parameter (recipient sid).
    $targetPath = $null
    [System.Threading.Monitor]::Enter($Global:UploadLock)
    try {
        $targetPath = Join-Path $ShareFolder $fileName
        if (Test-Path -LiteralPath $targetPath) {
            $base = [System.IO.Path]::GetFileNameWithoutExtension($fileName)
            $ext  = [System.IO.Path]::GetExtension($fileName)
            $n = 1
            do { $candidate = Join-Path $ShareFolder ("{0}_{1}{2}" -f $base,$n,$ext); $n++ } while (Test-Path -LiteralPath $candidate)
            $targetPath = $candidate
        }
        (New-Object System.IO.FileStream($targetPath,[System.IO.FileMode]::CreateNew,[System.IO.FileAccess]::Write,[System.IO.FileShare]::None)).Close()
    } catch {
        return @{ ok=$false; status=500; msg=$_.Exception.Message }
    } finally {
        [System.Threading.Monitor]::Exit($Global:UploadLock)
    }

    # Stream network to disk; stop marker is \r\n--boundary
    $delimBytes = $latin1.GetBytes("`r`n--" + $boundary)
    $delimLen   = $delimBytes.Length
    $chunkSize  = 262144                 # 256 KB
    $bufSize    = $chunkSize + $delimLen
    $buf        = New-Object byte[] $bufSize
    $bufLen     = 0
    $bytesWrote = 0L

    $fs = $null
    try {
        $fs = New-Object System.IO.FileStream($targetPath,[System.IO.FileMode]::Open,[System.IO.FileAccess]::Write,[System.IO.FileShare]::None,1048576,[System.IO.FileOptions]::SequentialScan)
        $found = $false

        while (-not $found) {
            $space = $bufSize - $bufLen
            $toRead = [Math]::Min($chunkSize, $space)
            if ($toRead -le 0) { $toRead = $chunkSize }
            $read = $NetStream.Read($buf, $bufLen, $toRead)
            if ($read -le 0) { break }
            $bufLen += $read

            $pos = [LFP.FastScan]::IndexOf($buf, 0, $bufLen, $delimBytes)
            if ($pos -ge 0) {
                if ($pos -gt 0) { $fs.Write($buf, 0, $pos); $bytesWrote += $pos }
                $found = $true
            } else {
                $safe = $bufLen - ($delimLen - 1)
                if ($safe -gt 0) {
                    $fs.Write($buf, 0, $safe); $bytesWrote += $safe
                    $keep = $bufLen - $safe
                    if ($keep -gt 0) { [System.Buffer]::BlockCopy($buf, $safe, $buf, 0, $keep) }
                    $bufLen = $keep
                }
            }
        }

        $fs.Flush()
    } catch {
        try { if ($fs) { $fs.Close() } } catch {}
        try { Remove-Item -LiteralPath $targetPath -Force -ErrorAction SilentlyContinue } catch {}
        return @{ ok=$false; status=500; msg=$_.Exception.Message }
    } finally {
        try { if ($fs) { $fs.Close() } } catch {}
    }

    $diskBase   = [System.IO.Path]::GetFileName($targetPath)
    # Display name = original relative path but with the (possibly deduped) basename.
    $displayName = if ($relPath -match '/') {
        ($relPath -replace '[^/]+$', '') + $diskBase
    } else { $diskBase }
    $size       = (Get-Item -LiteralPath $targetPath).Length
    $tid        = New-ShortId 8
    $senderNick = if ($Global:Sessions.ContainsKey($SenderSid)) { $Global:Sessions[$SenderSid].Nick } else { 'Unknown' }
    $t = @{
        Id=$tid; Name=$displayName; Path=$targetPath; Size=$size
        Sender=$SenderSid; SenderNick=$senderNick; Target=$Target
        BundleId=$BundleId
        Created=(Get-Date)
    }
    $Global:Transfers[$tid] = $t
    try { Save-TransferMeta -T $t } catch {}

    return @{ ok=$true; status=200; id=$tid; msg=$displayName }
}

# ============================== DOWNLOAD ======================================
function Send-FileDownload {
    param($Req, [System.IO.Stream]$Stream, [string]$Sid)
    $q = [System.Web.HttpUtility]::ParseQueryString($Req.Query)
    $id = $q['id']
    if ([string]::IsNullOrWhiteSpace($id) -or -not $Global:Transfers.ContainsKey($id)) {
        Send-HtmlResponse -Stream $Stream -Html '<h1>404 - file not found</h1>' -Status 404; return
    }
    $t = $Global:Transfers[$id]
    if ($t.Target -ne 'public' -and $t.Target -ne $Sid -and $t.Sender -ne $Sid) {
        Send-HtmlResponse -Stream $Stream -Html '<h1>403 - access denied</h1>' -Status 403; return
    }
    if (-not (Test-Path -LiteralPath $t.Path -PathType Leaf)) {
        Send-HtmlResponse -Stream $Stream -Html '<h1>404 - file missing on disk</h1>' -Status 404; return
    }

    $name    = [System.IO.Path]::GetFileName($t.Path)
    $nameEnc = [System.Web.HttpUtility]::UrlEncode($name) -replace '\+', '%20'
    $fi      = Get-Item -LiteralPath $t.Path

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("HTTP/1.1 200 OK`r`n")
    [void]$sb.Append("Content-Type: application/octet-stream`r`n")
    [void]$sb.Append("Content-Disposition: attachment; filename*=UTF-8''$nameEnc`r`n")
    [void]$sb.Append("Content-Length: $($fi.Length)`r`n")
    [void]$sb.Append("Cache-Control: no-store`r`n")
    [void]$sb.Append("Connection: close`r`n`r`n")
    $headBytes = [System.Text.Encoding]::GetEncoding(28591).GetBytes($sb.ToString())
    $Stream.Write($headBytes, 0, $headBytes.Length)

    $fs = New-Object System.IO.FileStream($t.Path,[System.IO.FileMode]::Open,[System.IO.FileAccess]::Read,[System.IO.FileShare]::Read,1048576,[System.IO.FileOptions]::SequentialScan)
    try {
        $buf = New-Object byte[] 262144
        while (($read = $fs.Read($buf, 0, $buf.Length)) -gt 0) {
            $Stream.Write($buf, 0, $read)
        }
        $Stream.Flush()
    } finally { $fs.Dispose() }
}

# ============================== BULK ZIP DOWNLOAD =============================
function Send-ZipDownload {
    param([string[]]$Ids, [string]$Sid, [System.IO.Stream]$Stream)

    # Filter to accessible + existing files
    $selected = @()
    foreach ($id in $Ids) {
        if (-not $Global:Transfers.ContainsKey($id)) { continue }
        $t = $Global:Transfers[$id]
        if ($t.Target -ne 'public' -and $t.Target -ne $Sid -and $t.Sender -ne $Sid) { continue }
        if (-not (Test-Path -LiteralPath $t.Path -PathType Leaf)) { continue }
        $selected += $t
    }
    if ($selected.Count -eq 0) {
        Send-HtmlResponse -Stream $Stream -Html '<h1>403 - no accessible files</h1>' -Status 403
        return
    }

    # Build ZIP into a temp file (seekable). Central directory finalized on dispose.
    $tmp = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), ('lfp-' + (New-ShortId 6) + '.zip'))
    try {
        $zipFs = [System.IO.File]::Open($tmp, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        try {
            $zip = New-Object System.IO.Compression.ZipArchive($zipFs, [System.IO.Compression.ZipArchiveMode]::Create, $false)
            try {
                $usedNames = @{}
                foreach ($t in $selected) {
                    $name = $t.Name
                    $key = $name.ToLowerInvariant()
                    if ($usedNames.ContainsKey($key)) {
                        $base = [System.IO.Path]::GetFileNameWithoutExtension($name)
                        $ext  = [System.IO.Path]::GetExtension($name)
                        $n = 1
                        do {
                            $name = "{0}_{1}{2}" -f $base, $n, $ext
                            $key  = $name.ToLowerInvariant()
                            $n++
                        } while ($usedNames.ContainsKey($key))
                    }
                    $usedNames[$key] = $true
                    $entry = $zip.CreateEntry($name, [System.IO.Compression.CompressionLevel]::Fastest)
                    $entryStream = $entry.Open()
                    try {
                        $src = New-Object System.IO.FileStream($t.Path,[System.IO.FileMode]::Open,[System.IO.FileAccess]::Read,[System.IO.FileShare]::Read,1048576,[System.IO.FileOptions]::SequentialScan)
                        try { $src.CopyTo($entryStream, 262144) } finally { $src.Close() }
                    } finally { $entryStream.Close() }
                }
            } finally { $zip.Dispose() }
        } finally { $zipFs.Close() }

        $zipSize = (Get-Item -LiteralPath $tmp).Length
        $zipName = 'transfers-' + (Get-Date).ToString('yyyyMMdd-HHmmss') + '.zip'
        $nameEnc = [System.Web.HttpUtility]::UrlEncode($zipName) -replace '\+', '%20'

        $sb = New-Object System.Text.StringBuilder
        [void]$sb.Append("HTTP/1.1 200 OK`r`n")
        [void]$sb.Append("Content-Type: application/zip`r`n")
        [void]$sb.Append("Content-Disposition: attachment; filename*=UTF-8''$nameEnc`r`n")
        [void]$sb.Append("Content-Length: $zipSize`r`n")
        [void]$sb.Append("Cache-Control: no-store`r`n")
        [void]$sb.Append("Connection: close`r`n`r`n")
        $headBytes = [System.Text.Encoding]::GetEncoding(28591).GetBytes($sb.ToString())
        $Stream.Write($headBytes, 0, $headBytes.Length)

        $fs = New-Object System.IO.FileStream($tmp,[System.IO.FileMode]::Open,[System.IO.FileAccess]::Read,[System.IO.FileShare]::Read,1048576,[System.IO.FileOptions]::SequentialScan)
        try {
            $buf = New-Object byte[] 262144
            while (($read = $fs.Read($buf, 0, $buf.Length)) -gt 0) {
                $Stream.Write($buf, 0, $read)
            }
            $Stream.Flush()
        } finally { $fs.Dispose() }
    } finally {
        try { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } catch {}
    }
}

# ============================== STATE JSON ====================================
function Get-StateJson {
    param([string]$Sid)
    Invoke-PeriodicSweep
    $me  = $Global:Sessions[$Sid]
    $now = Get-Date

    $devList = @()
    foreach ($k in @($Global:Sessions.Keys)) {
        $s = $Global:Sessions[$k]
        if ($null -eq $s) { continue }
        $ageSec = [int]([math]::Floor(($now - $s.LastSeen).TotalSeconds))
        $online = ($now - $s.LastSeen) -lt $Global:DeviceTTL
        $devList += [pscustomobject]@{
            pubId  = $s.PubId
            nick   = $s.Nick
            ageSec = $ageSec
            online = $online
        }
    }
    $devList = @($devList | Sort-Object -Property @{Expression={[int]$_.online};Descending=$true}, ageSec)

    # Split visible transfers into standalone singles + bundle groups (by BundleId)
    $singles = @()
    $bundles = @{}
    foreach ($k in @($Global:Transfers.Keys)) {
        $t = $Global:Transfers[$k]
        if ($null -eq $t) { continue }
        if (-not ($t.Target -eq 'public' -or $t.Target -eq $Sid -or $t.Sender -eq $Sid)) { continue }
        if ($t.BundleId) {
            if (-not $bundles.ContainsKey($t.BundleId)) { $bundles[$t.BundleId] = New-Object System.Collections.Generic.List[object] }
            [void]$bundles[$t.BundleId].Add($t)
        } else {
            $singles += $t
        }
    }

    $entries = @()

    foreach ($t in $singles) {
        $targetNick = 'Everyone'; $targetKind = 'public'
        if ($t.Target -ne 'public') {
            $targetKind = 'device'
            if ($Global:Sessions.ContainsKey($t.Target)) { $targetNick = $Global:Sessions[$t.Target].Nick }
            else { $targetNick = '(deleted)' }
        }
        $entries += [pscustomobject]@{
            kind       = 'single'
            id         = $t.Id
            name       = $t.Name
            size       = $t.Size
            senderNick = $t.SenderNick
            targetNick = $targetNick
            target     = $targetKind
            byMe       = ($t.Sender -eq $Sid)
            toMe       = ($t.Target -eq $Sid)
            created    = $t.Created.ToString('o')
            icon       = (Get-IconForFile $t.Name)
        }
    }

    foreach ($bid in @($bundles.Keys)) {
        $items = @($bundles[$bid] | Sort-Object { $_.Created })
        if ($items.Count -eq 0) { continue }
        $first = $items[0]
        $totalSize = 0L; foreach ($ii in $items) { $totalSize += [int64]$ii.Size }
        $minCreated = $first.Created
        foreach ($ii in $items) { if ($ii.Created -lt $minCreated) { $minCreated = $ii.Created } }
        $targetNick = 'Everyone'; $targetKind = 'public'
        if ($first.Target -ne 'public') {
            $targetKind = 'device'
            if ($Global:Sessions.ContainsKey($first.Target)) { $targetNick = $Global:Sessions[$first.Target].Nick }
            else { $targetNick = '(deleted)' }
        }
        $childArr = @()
        foreach ($ii in $items) {
            $childArr += [pscustomobject]@{
                id   = $ii.Id
                name = $ii.Name
                size = $ii.Size
                icon = (Get-IconForFile $ii.Name)
            }
        }
        $entries += [pscustomobject]@{
            kind       = 'bundle'
            bundleId   = $bid
            name       = ("Bundle - {0} files" -f $items.Count)
            size       = $totalSize
            senderNick = $first.SenderNick
            targetNick = $targetNick
            target     = $targetKind
            byMe       = ($first.Sender -eq $Sid)
            toMe       = ($first.Target -eq $Sid)
            created    = $minCreated.ToString('o')
            count      = $items.Count
            items      = $childArr
        }
    }

    $entries = @($entries | Sort-Object { $_.created } -Descending)

    $payload = [pscustomobject]@{
        me = [pscustomobject]@{ pubId = $me.PubId; nick = $me.Nick }
        devices   = $devList
        transfers = $entries
    }
    return ($payload | ConvertTo-Json -Depth 8 -Compress)
}

# ============================== UI PAGES ======================================
function Get-LoginPage {
    param([bool]$Error = $false)
    $errBlock = if ($Error) { '<div class="error-msg">Wrong password. Please try again.</div>' } else { '' }
    return @"
<!DOCTYPE html><html lang="en"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Local File Portal - Sign In</title>
<style>
  :root{--bg:#0d0f12;--card:#141720;--border:#1e2330;--accent:#4f8ef7;--text:#e8ecf5;--muted:#5a6480;--ok:#4ff78e;--err:#f74f6a}
  *{box-sizing:border-box;margin:0;padding:0}
  body{font-family:'Segoe UI',system-ui,sans-serif;background:var(--bg);color:var(--text);min-height:100vh;display:flex;align-items:center;justify-content:center;overflow:hidden}
  .grid-bg{position:fixed;inset:0;z-index:0;background-image:linear-gradient(rgba(79,142,247,.07) 1px,transparent 1px),linear-gradient(90deg,rgba(79,142,247,.07) 1px,transparent 1px);background-size:42px 42px;animation:drift 22s linear infinite}
  @keyframes drift{from{background-position:0 0}to{background-position:42px 42px}}
  .card{position:relative;z-index:1;background:var(--card);border:1px solid var(--border);border-radius:18px;padding:42px 38px;width:380px;max-width:92vw;box-shadow:0 24px 60px rgba(0,0,0,.55)}
  .logo{display:flex;align-items:center;gap:12px;margin-bottom:6px}.logo .icon{font-size:34px}.logo h1{font-size:20px;font-weight:700;letter-spacing:.5px}
  .sub{color:var(--muted);font-size:13px;margin-bottom:26px}
  label{display:block;font-size:12px;color:var(--muted);margin-bottom:8px;text-transform:uppercase;letter-spacing:1px}
  .pw-wrap{position:relative;margin-bottom:18px}
  input{width:100%;padding:13px 46px 13px 14px;background:var(--bg);border:1px solid var(--border);border-radius:10px;color:var(--text);font-size:15px;outline:none;transition:border .2s}
  input:focus{border-color:var(--accent)}
  .toggle{position:absolute;right:8px;top:50%;transform:translateY(-50%);background:none;border:none;color:var(--muted);cursor:pointer;font-size:18px;padding:6px}
  button.submit{width:100%;padding:13px;background:var(--accent);color:#fff;border:none;border-radius:10px;font-size:15px;font-weight:600;cursor:pointer}
  button.submit:hover{filter:brightness(1.1)}
  .error-msg{background:rgba(247,79,106,.12);border:1px solid var(--err);color:var(--err);padding:10px 12px;border-radius:8px;font-size:13px;margin-bottom:18px}
  .status{display:flex;align-items:center;gap:8px;margin-top:22px;font-size:12px;color:var(--muted);justify-content:center}
  .dot{width:9px;height:9px;border-radius:50%;background:var(--ok);box-shadow:0 0 8px var(--ok);animation:blink 1.4s ease-in-out infinite}
  @keyframes blink{0%,100%{opacity:1}50%{opacity:.25}}
</style></head><body>
  <div class="grid-bg"></div>
  <div class="card">
    <div class="logo"><span class="icon">&#128274;</span><h1>LOCAL FILE PORTAL</h1></div>
    <div class="sub">Pick a device name (optional) and sign in.</div>
    $errBlock
    <form method="POST" action="/">
      <label for="nick">Device Name</label>
      <input id="nick" name="nick" type="text" placeholder="e.g. Hakan's Phone" maxlength="32" style="margin-bottom:16px">
      <label for="pw">Password</label>
      <div class="pw-wrap">
        <input id="pw" name="password" type="password" placeholder="&#8226;&#8226;&#8226;&#8226;&#8226;&#8226;" autofocus required>
        <button type="button" class="toggle" id="tgl" title="Show/Hide">&#128065;</button>
      </div>
      <button type="submit" class="submit">Sign In</button>
    </form>
    <div class="status"><span class="dot"></span> Server online</div>
  </div>
<script>
  var pw=document.getElementById('pw'),tgl=document.getElementById('tgl');
  tgl.addEventListener('click',function(){if(pw.type==='password'){pw.type='text';tgl.style.color='#4f8ef7';}else{pw.type='password';tgl.style.color='';}});
</script>
</body></html>
"@
}

function Get-DashboardPage {
    return @"
<!DOCTYPE html><html lang="en"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Local File Portal</title>
<style>
  :root{--bg:#0d0f12;--card:#141720;--border:#1e2330;--accent:#4f8ef7;--accent2:#8e6cf7;--text:#e8ecf5;--muted:#5a6480;--ok:#4ff78e;--err:#f74f6a;--warn:#f7c14f}
  *{box-sizing:border-box;margin:0;padding:0}
  body{font-family:'Segoe UI',system-ui,sans-serif;background:var(--bg);color:var(--text);min-height:100vh}
  header{position:sticky;top:0;z-index:10;background:rgba(20,23,32,.92);backdrop-filter:blur(8px);border-bottom:1px solid var(--border);padding:14px 24px;display:flex;align-items:center;justify-content:space-between;gap:16px;flex-wrap:wrap}
  .brand{display:flex;align-items:center;gap:11px}.brand .icon{font-size:24px}.brand h1{font-size:16px;letter-spacing:.5px}
  .hdr-right{display:flex;align-items:center;gap:14px;font-size:13px;flex-wrap:wrap}
  .me-chip{display:flex;align-items:center;gap:8px;background:var(--bg);border:1px solid var(--border);padding:6px 12px;border-radius:20px}
  .me-chip .dot{width:8px;height:8px;border-radius:50%;background:var(--ok);box-shadow:0 0 6px var(--ok)}
  .me-chip b{font-weight:600}
  .me-chip .rename{background:none;border:none;color:var(--muted);cursor:pointer;font-size:14px;padding:0 2px}
  .me-chip .rename:hover{color:var(--accent)}
  .logout{color:var(--err);text-decoration:none;font-size:13px;border:1px solid var(--border);padding:6px 12px;border-radius:8px}
  .logout:hover{background:rgba(247,79,106,.1)}
  main{max-width:1100px;margin:0 auto;padding:24px}
  .panel{background:var(--card);border:1px solid var(--border);border-radius:14px;padding:20px;margin-bottom:22px}
  .panel h2{font-size:13px;text-transform:uppercase;letter-spacing:1.5px;color:var(--muted);margin-bottom:14px;display:flex;align-items:center;gap:10px;flex-wrap:wrap}
  .target-chip{background:rgba(79,142,247,.15);color:var(--accent);padding:4px 10px;border-radius:14px;font-size:12px;text-transform:none;letter-spacing:0;font-weight:600}
  .dev-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(170px,1fr));gap:10px}
  .dev{background:var(--bg);border:1px solid var(--border);border-radius:11px;padding:14px;cursor:pointer;transition:all .15s;display:flex;flex-direction:column;gap:4px;position:relative;min-height:96px}
  .dev:hover{border-color:var(--accent);transform:translateY(-1px)}
  .dev.selected{border-color:var(--accent);background:rgba(79,142,247,.08);box-shadow:0 0 0 2px rgba(79,142,247,.25)}
  .dev.public{background:linear-gradient(135deg,rgba(79,142,247,.08),rgba(142,108,247,.08));border-color:rgba(79,142,247,.3)}
  .dev.offline{opacity:.45}
  .dev.self{border-style:dashed;cursor:not-allowed;opacity:.55}
  .dev-icon{font-size:22px}
  .dev-name{font-size:14px;font-weight:600;word-break:break-all}
  .dev-sub{font-size:11px;color:var(--muted)}
  .dev-status{position:absolute;top:10px;right:10px;width:8px;height:8px;border-radius:50%;background:var(--ok);box-shadow:0 0 6px var(--ok)}
  .dev.offline .dev-status{background:var(--muted);box-shadow:none}
  .drop{border:2px dashed var(--border);border-radius:12px;padding:34px;text-align:center;color:var(--muted);cursor:pointer;transition:all .2s}
  .drop.over{border-color:var(--accent);background:rgba(79,142,247,.06);color:var(--text)}
  .drop .big{font-size:36px;margin-bottom:8px}
  .filelist{display:flex;flex-direction:column;gap:8px;margin:14px 0 0}
  .fileitem{display:flex;align-items:center;gap:12px;padding:9px 13px;background:var(--bg);border:1px solid var(--border);border-radius:10px;font-size:13px}
  .fileitem .fi-ic{font-size:18px}.fileitem .fi-name{flex:1;word-break:break-all}.fileitem .fi-size{color:var(--muted);font-size:12px;white-space:nowrap}
  .fileitem .fi-stat{font-size:12px;white-space:nowrap}
  .fileitem .fi-stat.ok{color:var(--ok)}.fileitem .fi-stat.err{color:var(--err)}.fileitem .fi-stat.up{color:var(--accent)}
  .fileitem .fi-x{cursor:pointer;color:var(--err);font-weight:700;padding:0 4px}
  .bar-wrap{display:none;margin-top:14px;background:var(--bg);border-radius:30px;overflow:hidden;height:8px;border:1px solid var(--border)}
  .bar-wrap.show{display:block}.bar{height:100%;width:0;background:linear-gradient(90deg,var(--accent),var(--accent2));transition:width .12s}
  .up-row{display:flex;align-items:center;gap:12px;margin-top:14px;flex-wrap:wrap}
  .btn{padding:10px 20px;background:var(--accent);color:#fff;border:none;border-radius:9px;font-size:14px;font-weight:600;cursor:pointer}
  .btn:disabled{opacity:.5;cursor:not-allowed}
  .btn.ghost{background:transparent;border:1px solid var(--border);color:var(--muted)}.btn.ghost:hover{color:var(--text)}
  .count-lbl{color:var(--muted);font-size:13px;margin-left:auto}
  .tabs{display:flex;gap:6px;margin-bottom:12px;flex-wrap:wrap}
  .tab{padding:6px 14px;background:transparent;border:1px solid var(--border);color:var(--muted);border-radius:8px;font-size:13px;cursor:pointer}
  .tab.on{background:rgba(79,142,247,.15);color:var(--accent);border-color:var(--accent)}
  input[type="checkbox"]{accent-color:var(--accent);cursor:pointer;width:15px;height:15px;margin:0;vertical-align:middle}
  .bundle-row td{background:rgba(142,108,247,.05)}
  .bundle-row:hover td{background:rgba(142,108,247,.09)}
  .bundle-child td{background:rgba(79,142,247,.03);border-bottom:1px dashed var(--border);font-size:12.5px}
  .bundle-child td.child-nm{color:var(--muted);padding-left:22px}
  .expand-btn{background:none;border:1px solid var(--border);color:var(--muted);cursor:pointer;padding:1px 7px;border-radius:5px;font-size:11px;margin-right:6px;font-family:inherit}
  .expand-btn:hover{color:var(--accent);border-color:var(--accent)}
  .folder-crumb{color:var(--muted);font-size:11px}
  .bundle-dl{background:rgba(142,108,247,.12);padding:3px 9px;border-radius:6px;color:var(--accent2)!important}
  table{width:100%;border-collapse:collapse}
  th{text-align:left;font-size:11px;text-transform:uppercase;letter-spacing:1px;color:var(--muted);padding:8px 10px;border-bottom:1px solid var(--border)}
  td{padding:11px 10px;border-bottom:1px solid var(--border);font-size:13.5px;vertical-align:middle}
  td.ic{font-size:18px;width:36px}.td-nm{word-break:break-all}
  td.dt{color:var(--muted);font-size:12px;white-space:nowrap}
  tr:last-child td{border-bottom:none}tr:hover td{background:rgba(79,142,247,.04)}
  .pill{display:inline-block;padding:2px 8px;border-radius:11px;font-size:11px;background:rgba(79,142,247,.12);color:var(--accent);margin-right:4px;white-space:nowrap}
  .pill.pub{background:rgba(142,108,247,.15);color:var(--accent2)}
  .pill.me{background:rgba(79,247,142,.12);color:var(--ok)}
  .dl{color:var(--accent);text-decoration:none;font-size:13px;white-space:nowrap}.dl:hover{text-decoration:underline}
  .dl-x{background:none;border:1px solid var(--err);color:var(--err);padding:2px 8px;border-radius:6px;font-size:12px;cursor:pointer;margin-left:6px}
  .dl-x:hover{background:rgba(247,79,106,.12)}
  .empty{text-align:center;color:var(--muted);padding:28px;font-size:14px}
  .toast-box{position:fixed;right:22px;bottom:22px;z-index:50;display:flex;flex-direction:column;gap:10px}
  .toast{padding:12px 18px;border-radius:10px;font-size:13px;box-shadow:0 10px 30px rgba(0,0,0,.5);animation:slidein .25s ease;min-width:220px;max-width:380px}
  .toast.ok{background:#16321f;border:1px solid var(--ok);color:var(--ok)}
  .toast.err{background:#321016;border:1px solid var(--err);color:var(--err)}
  .toast.info{background:#15243a;border:1px solid var(--accent);color:var(--accent)}
  @keyframes slidein{from{transform:translateX(120%);opacity:0}to{transform:translateX(0);opacity:1}}
  @media(max-width:600px){header{padding:12px 14px}main{padding:14px}.panel{padding:16px}}
</style></head><body>
  <header>
    <div class="brand"><span class="icon">&#128193;</span><h1>LOCAL FILE PORTAL</h1></div>
    <div class="hdr-right">
      <div class="me-chip">
        <span class="dot"></span><span>Me:</span>
        <b id="myNick">...</b>
        <button class="rename" id="renameBtn" title="Change device name">&#9998;</button>
      </div>
      <span id="onlineCount" style="color:var(--muted)">...</span>
      <a class="logout" href="/logout">&#128682; Sign Out</a>
    </div>
  </header>

  <main>
    <section class="panel">
      <h2>Connected Devices <span id="targetLabel" class="target-chip">Target: Everyone</span></h2>
      <div id="devices" class="dev-grid"></div>
    </section>

    <section class="panel">
      <h2>Send Files</h2>
      <div class="drop" id="drop">
        <div class="big">&#128228;</div>
        <div>Drag and drop files here <br>or click to select <b>multiple</b> files</div>
        <input type="file" id="file" multiple hidden>
      </div>
      <div class="filelist" id="fileList"></div>
      <div class="up-row">
        <button class="btn" id="upBtn" disabled>Send</button>
        <button class="btn ghost" id="clearBtn" style="display:none">Clear</button>
        <span class="count-lbl" id="countLbl"></span>
      </div>
      <div class="bar-wrap" id="barWrap"><div class="bar" id="bar"></div></div>
    </section>

    <section class="panel">
      <h2>Transfers</h2>
      <div class="tabs">
        <button class="tab on" data-f="all">All</button>
        <button class="tab" data-f="inbox">Inbox</button>
        <button class="tab" data-f="public">Public</button>
        <button class="tab" data-f="sent">Sent</button>
        <button class="btn zip-btn" id="zipBtn" disabled style="margin-left:auto;padding:6px 14px;font-size:13px">&#128230; Download Selected (0)</button>
      </div>
      <table>
        <thead><tr><th style="width:28px"><input type="checkbox" id="selAll" title="Select all"></th><th></th><th>File</th><th>Size</th><th>From / To</th><th>Date</th><th></th></tr></thead>
        <tbody id="transferBody"></tbody>
      </table>
    </section>
  </main>

  <div class="toast-box" id="toasts"></div>

<script>
  var state={me:{},devices:[],transfers:[]};
  var target='public';
  var queued=[];
  var uploading=false;
  var seq=0;
  var filter='all';
  var toasts=document.getElementById('toasts');
  var lastEntryKeys=null;      // null = initial load; skip toasts until first fetch completes
  var selectedIds=new Set();   // individual transfer ids (children of bundles included)
  var expandedBundles=new Set();

  function randomHex(n){var s='',cs='0123456789abcdef';for(var i=0;i<n*2;i++)s+=cs[Math.floor(Math.random()*16)];return s;}
  function entryKey(t){return t.kind==='bundle' ? ('b:'+t.bundleId) : ('s:'+t.id);}

  function esc(s){return String(s).replace(/[&<>"]/g,function(c){return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c];});}
  function toast(msg,type){var t=document.createElement('div');t.className='toast '+(type||'ok');t.textContent=msg;toasts.appendChild(t);setTimeout(function(){t.style.transition='opacity .3s';t.style.opacity='0';setTimeout(function(){t.remove();},300);},3500);}
  function fmtSize(b){if(b>=1073741824)return(b/1073741824).toFixed(2)+' GB';if(b>=1048576)return(b/1048576).toFixed(2)+' MB';if(b>=1024)return(b/1024).toFixed(2)+' KB';return b+' B';}
  function fmtSeen(sec){if(sec<60)return 'just now';if(sec<3600)return Math.floor(sec/60)+'m ago';if(sec<86400)return Math.floor(sec/3600)+'h ago';return Math.floor(sec/86400)+'d ago';}
  function fmtDate(iso){var d=new Date(iso);if(isNaN(d.getTime()))return iso;var y=d.getFullYear(),m=('0'+(d.getMonth()+1)).slice(-2),da=('0'+d.getDate()).slice(-2);var h=('0'+d.getHours()).slice(-2),mi=('0'+d.getMinutes()).slice(-2);return da+'.'+m+'.'+y+' '+h+':'+mi;}
  function devIcon(n){var s=(n||'').toLowerCase();if(s.indexOf('iphone')>=0||s.indexOf('ipad')>=0||s.indexOf('android')>=0)return '&#128241;';if(s.indexOf('mac')>=0||s.indexOf('windows')>=0)return '&#128187;';if(s.indexOf('linux')>=0)return '&#128421;';return '&#128242;';}

  async function fetchState(){
    if(uploading)return;
    try{
      var r=await fetch('/api/state',{cache:'no-store'});
      if(r.status===401){location.href='/';return;}
      if(!r.ok)return;
      var prev=lastEntryKeys;
      state=await r.json();
      lastEntryKeys=new Set(state.transfers.map(entryKey));
      // Only toast when we have a prior snapshot to diff against. Skips initial load.
      if(prev!==null){
        state.transfers.forEach(function(t){
          if(prev.has(entryKey(t)))return;
          if(t.byMe)return;
          if(!(t.toMe || t.target==='public'))return;
          if(t.kind==='bundle'){
            toast(t.senderNick+' sent you a bundle ('+t.count+' files)','info');
          } else {
            toast(t.senderNick+' sent you: '+t.name,'info');
          }
        });
      }
      renderAll();
    }catch(e){}
  }
  function renderAll(){
    document.getElementById('myNick').textContent=state.me.nick||'...';
    var others=state.devices.filter(function(d){return d.pubId!==state.me.pubId;});
    var onN=others.filter(function(d){return d.online;}).length;
    document.getElementById('onlineCount').textContent=onN+' other device(s) online';
    if(target!=='public' && !state.devices.some(function(d){return d.pubId===target;})){
      target='public';
    }
    renderDevices();
    renderTransfers();
    refreshTargetLabel();
  }
  function devCard(pubId,icon,label,sub,offline,self,showStatus){
    var c=document.createElement('div');
    c.className='dev'+(pubId===target?' selected':'')+(offline?' offline':'')+(self?' self':'')+(pubId==='public'?' public':'');
    var status=(showStatus && !self)?'<div class="dev-status"></div>':'';
    c.innerHTML=status+'<div class="dev-icon">'+icon+'</div><div class="dev-name">'+esc(label)+(self?' (me)':'')+'</div><div class="dev-sub">'+esc(sub)+'</div>';
    c.addEventListener('click',function(){
      if(self){toast("Can't send to yourself",'err');return;}
      target=pubId; renderDevices(); refreshTargetLabel();
    });
    return c;
  }
  function renderDevices(){
    var box=document.getElementById('devices');box.innerHTML='';
    box.appendChild(devCard('public','&#127760;','Everyone (Public)','Visible to all devices',false,false,false));
    state.devices.forEach(function(d){
      var sub=d.online?'online':fmtSeen(d.ageSec);
      box.appendChild(devCard(d.pubId,devIcon(d.nick),d.nick,sub,!d.online,d.pubId===state.me.pubId,true));
    });
  }
  function refreshTargetLabel(){
    var name='Everyone';
    if(target!=='public'){var d=state.devices.find(function(x){return x.pubId===target;});name=d?d.nick:'(none)';}
    document.getElementById('targetLabel').textContent='Target: '+name;
  }
  function renderTransfers(){
    var body=document.getElementById('transferBody');body.innerHTML='';
    var rows=state.transfers.filter(function(t){
      if(filter==='all')return true;
      if(filter==='public')return t.target==='public';
      if(filter==='inbox')return !t.byMe && (t.target==='public' || t.toMe);
      if(filter==='sent')return t.byMe;
      return true;
    });
    // Drop selected ids that no longer exist
    var liveIds=new Set();
    state.transfers.forEach(function(t){
      if(t.kind==='bundle'){t.items.forEach(function(it){liveIds.add(it.id);});}
      else{liveIds.add(t.id);}
    });
    selectedIds.forEach(function(id){if(!liveIds.has(id))selectedIds.delete(id);});
    if(rows.length===0){body.innerHTML='<tr><td colspan="7" class="empty">&#128230; No files yet.</td></tr>';syncSelAll();updateZipBtn();return;}
    rows.forEach(function(t){
      if(t.kind==='bundle')renderBundleRow(body,t);
      else renderSingleRow(body,t);
    });
    syncSelAll();
    updateZipBtn();
  }
  function renderSingleRow(body,t){
    var tr=document.createElement('tr');
    var pill=t.target==='public'?'<span class="pill pub">&#127760; Public</span>':('<span class="pill">'+esc(t.targetNick)+'</span>');
    var fromPill=t.byMe?'<span class="pill me">Me</span>':('<span class="pill">'+esc(t.senderNick)+'</span>');
    var del=t.byMe?'<button class="dl-x" data-id="'+t.id+'" title="Delete">&#10005;</button>':'';
    var chk=selectedIds.has(t.id)?' checked':'';
    tr.innerHTML='<td class="ic"><input type="checkbox" class="rowChk" data-id="'+t.id+'"'+chk+'></td>'+
                 '<td class="ic">'+t.icon+'</td>'+
                 '<td class="td-nm">'+esc(t.name)+'</td>'+
                 '<td>'+fmtSize(t.size)+'</td>'+
                 '<td>'+fromPill+' &rarr; '+pill+'</td>'+
                 '<td class="dt">'+fmtDate(t.created)+'</td>'+
                 '<td><a class="dl" href="/download?id='+encodeURIComponent(t.id)+'">&#11015; Download</a>'+del+'</td>';
    body.appendChild(tr);
  }
  function renderBundleRow(body,t){
    var expanded=expandedBundles.has(t.bundleId);
    var arrow=expanded?'&#9662;':'&#9656;';   // filled tri down / right
    var pill=t.target==='public'?'<span class="pill pub">&#127760; Public</span>':('<span class="pill">'+esc(t.targetNick)+'</span>');
    var fromPill=t.byMe?'<span class="pill me">Me</span>':('<span class="pill">'+esc(t.senderNick)+'</span>');
    var del=t.byMe?'<button class="dl-x" data-bundle="'+t.bundleId+'" title="Delete bundle">&#10005;</button>':'';
    // Bundle checkbox reflects: all children currently selected?
    var childIds=t.items.map(function(x){return x.id;});
    var allSel=childIds.length>0 && childIds.every(function(id){return selectedIds.has(id);});
    var anySel=childIds.some(function(id){return selectedIds.has(id);});
    var chk=allSel?' checked':'';
    var tr=document.createElement('tr');
    tr.className='bundle-row';
    tr.innerHTML='<td class="ic"><input type="checkbox" class="bundleChk" data-bundle="'+t.bundleId+'"'+chk+'></td>'+
                 '<td class="ic">&#128230;</td>'+
                 '<td class="td-nm"><button class="expand-btn" data-bundle="'+t.bundleId+'">'+arrow+'</button> Bundle &middot; '+t.count+' files</td>'+
                 '<td>'+fmtSize(t.size)+'</td>'+
                 '<td>'+fromPill+' &rarr; '+pill+'</td>'+
                 '<td class="dt">'+fmtDate(t.created)+'</td>'+
                 '<td><a class="dl bundle-dl" href="#" data-bundle="'+t.bundleId+'">&#128230; ZIP</a>'+del+'</td>';
    body.appendChild(tr);
    if(anySel && !allSel){
      var bc=tr.querySelector('.bundleChk'); if(bc)bc.indeterminate=true;
    }
    if(expanded){
      // Render nested folder tree from item.name (slash-delimited)
      renderBundleTree(body,t);
    }
  }
  function renderBundleTree(body,t){
    // Group items by folder prefix; render sub-rows with indent.
    t.items.forEach(function(item){
      var parts=item.name.split('/');
      var base=parts[parts.length-1];
      var folder=parts.slice(0,-1).join('/');
      var subTr=document.createElement('tr');
      subTr.className='bundle-child';
      var indent=parts.length>1 ? ('&nbsp;&nbsp;'.repeat(parts.length-1)) : '';
      var prefix=folder ? ('<span class="folder-crumb">'+esc(folder)+'/</span>') : '';
      var chk=selectedIds.has(item.id)?' checked':'';
      var owned=t.byMe;
      var del=owned?'<button class="dl-x" data-id="'+item.id+'" title="Delete file">&#10005;</button>':'';
      subTr.innerHTML='<td class="ic"><input type="checkbox" class="rowChk" data-id="'+item.id+'" data-bundle="'+t.bundleId+'"'+chk+'></td>'+
                      '<td class="ic">'+item.icon+'</td>'+
                      '<td class="td-nm child-nm">'+indent+'&#8735; '+prefix+esc(base)+'</td>'+
                      '<td>'+fmtSize(item.size)+'</td>'+
                      '<td></td><td></td>'+
                      '<td><a class="dl" href="/download?id='+encodeURIComponent(item.id)+'">&#11015;</a>'+del+'</td>';
      body.appendChild(subTr);
    });
  }
  function updateZipBtn(){
    var n=selectedIds.size;
    var b=document.getElementById('zipBtn');
    b.disabled=(n===0);
    b.innerHTML='&#128230; Download Selected ('+n+')';
  }
  function syncSelAll(){
    var chks=document.querySelectorAll('.rowChk');
    var sa=document.getElementById('selAll');
    if(chks.length===0){sa.checked=false;sa.indeterminate=false;return;}
    var checkedN=0;
    chks.forEach(function(c){if(c.checked)checkedN++;});
    sa.checked=(checkedN===chks.length);
    sa.indeterminate=(checkedN>0 && checkedN<chks.length);
  }

  document.querySelectorAll('.tab').forEach(function(b){b.addEventListener('click',function(){
    document.querySelectorAll('.tab').forEach(function(x){x.classList.remove('on');});
    b.classList.add('on');filter=b.dataset.f;renderTransfers();
  });});
  function submitZipForm(spec){
    var f=document.createElement('form');
    f.method='POST'; f.action='/api/zip'; f.target='_blank';
    (spec.ids||[]).forEach(function(id){var i=document.createElement('input');i.type='hidden';i.name='id';i.value=id;f.appendChild(i);});
    (spec.bundles||[]).forEach(function(bid){var i=document.createElement('input');i.type='hidden';i.name='bundle';i.value=bid;f.appendChild(i);});
    document.body.appendChild(f); f.submit();
    setTimeout(function(){document.body.removeChild(f);},1000);
  }
  document.getElementById('transferBody').addEventListener('click',async function(e){
    // Expand/collapse a bundle
    var eb=e.target.closest('.expand-btn');
    if(eb){
      var bid=eb.dataset.bundle;
      if(expandedBundles.has(bid))expandedBundles.delete(bid);
      else expandedBundles.add(bid);
      renderTransfers();
      return;
    }
    // Bundle ZIP download
    var bd=e.target.closest('.bundle-dl');
    if(bd){
      e.preventDefault();
      submitZipForm({bundles:[bd.dataset.bundle]});
      toast('Preparing ZIP...','info');
      return;
    }
    // Delete: single file OR whole bundle
    var x=e.target.closest('.dl-x');
    if(!x)return;
    var bid=x.dataset.bundle;
    var id=x.dataset.id;
    if(bid){
      if(!confirm('Delete this entire bundle from the server?'))return;
      var fd=new FormData(); fd.append('bundle',bid);
      var r=await fetch('/api/delete',{method:'POST',body:fd});
      if(r.ok){toast('Bundle deleted','ok');fetchState();}else{toast('Delete failed','err');}
    } else if(id){
      if(!confirm('Permanently delete this file?'))return;
      var fd=new FormData(); fd.append('id',id);
      var r=await fetch('/api/delete',{method:'POST',body:fd});
      if(r.ok){toast('Deleted','ok');fetchState();}else{toast('Delete failed','err');}
    }
  });
  document.getElementById('transferBody').addEventListener('change',function(e){
    // Bundle master checkbox: toggles all children
    var bc=e.target.closest('.bundleChk');
    if(bc){
      var bid=bc.dataset.bundle;
      var bundle=state.transfers.find(function(x){return x.kind==='bundle' && x.bundleId===bid;});
      if(bundle){
        bundle.items.forEach(function(item){
          if(bc.checked)selectedIds.add(item.id); else selectedIds.delete(item.id);
        });
        document.querySelectorAll('.rowChk[data-bundle="'+bid+'"]').forEach(function(c){c.checked=bc.checked;});
      }
      updateZipBtn(); syncSelAll();
      return;
    }
    // Individual row checkbox (single OR bundle child)
    var c=e.target.closest('.rowChk');
    if(!c)return;
    var id=c.dataset.id;
    if(c.checked)selectedIds.add(id); else selectedIds.delete(id);
    // If it's a bundle child, sync the parent bundleChk (checked/indeterminate)
    var parentBid=c.dataset.bundle;
    if(parentBid){
      var parent=state.transfers.find(function(x){return x.kind==='bundle' && x.bundleId===parentBid;});
      if(parent){
        var childIds=parent.items.map(function(it){return it.id;});
        var checkedN=childIds.filter(function(cid){return selectedIds.has(cid);}).length;
        var bChk=document.querySelector('.bundleChk[data-bundle="'+parentBid+'"]');
        if(bChk){
          bChk.checked=(checkedN===childIds.length);
          bChk.indeterminate=(checkedN>0 && checkedN<childIds.length);
        }
      }
    }
    updateZipBtn(); syncSelAll();
  });
  document.getElementById('selAll').addEventListener('change',function(){
    var chk=document.getElementById('selAll').checked;
    document.querySelectorAll('.rowChk').forEach(function(c){
      c.checked=chk;
      var id=c.dataset.id; if(!id)return;
      if(chk)selectedIds.add(id); else selectedIds.delete(id);
    });
    document.querySelectorAll('.bundleChk').forEach(function(bc){bc.checked=chk;bc.indeterminate=false;});
    updateZipBtn();
  });
  document.getElementById('zipBtn').addEventListener('click',function(){
    if(selectedIds.size===0)return;
    submitZipForm({ids:Array.from(selectedIds)});
    toast('Preparing ZIP ('+selectedIds.size+' files)...','info');
  });
  document.getElementById('renameBtn').addEventListener('click',async function(){
    var n=prompt('New device name:',state.me.nick);if(!n)return;
    n=n.trim().slice(0,32);if(!n)return;
    var fd=new FormData();fd.append('nick',n);
    var r=await fetch('/api/nick',{method:'POST',body:fd});
    if(r.ok){toast('Name updated','ok');fetchState();}
  });

  var drop=document.getElementById('drop'),fileInp=document.getElementById('file'),
      fileList=document.getElementById('fileList'),barWrap=document.getElementById('barWrap'),
      bar=document.getElementById('bar'),upBtn=document.getElementById('upBtn'),
      clearBtn=document.getElementById('clearBtn'),countLbl=document.getElementById('countLbl');

  function addFiles(list){
    if(uploading)return;
    Array.prototype.forEach.call(list,function(f){
      var dup=queued.some(function(q){return q.file.name===f.name && q.file.size===f.size;});
      if(!dup){queued.push({file:f,id:++seq,status:'wait'});}
    });
    renderQueue();
  }
  function renderQueue(){
    fileList.innerHTML='';
    queued.forEach(function(q){
      var row=document.createElement('div');row.className='fileitem';
      var stat='';
      if(q.status==='ok')stat='<span class="fi-stat ok">&#10003; sent</span>';
      else if(q.status==='err')stat='<span class="fi-stat err">&#10007; error</span>';
      else if(q.status==='up')stat='<span class="fi-stat up">sending...</span>';
      var rm=uploading?'':'<span class="fi-x" data-id="'+q.id+'">&#10005;</span>';
      row.innerHTML='<span class="fi-ic">&#128196;</span><span class="fi-name">'+esc(q.file.name)+'</span><span class="fi-size">'+fmtSize(q.file.size)+'</span>'+stat+rm;
      fileList.appendChild(row);
    });
    upBtn.disabled=(queued.length===0 || uploading);
    clearBtn.style.display=(queued.length && !uploading)?'inline-block':'none';
    countLbl.textContent=queued.length?(queued.length+' file(s) '+(uploading?'sending':'selected')):'';
  }
  fileList.addEventListener('click',function(e){
    var x=e.target.closest('.fi-x');if(!x)return;
    var id=parseInt(x.dataset.id,10);
    queued=queued.filter(function(q){return q.id!==id;});renderQueue();
  });
  drop.addEventListener('click',function(){if(!uploading)fileInp.click();});
  fileInp.addEventListener('change',function(){addFiles(fileInp.files);fileInp.value='';});
  ['dragenter','dragover'].forEach(function(e){drop.addEventListener(e,function(ev){ev.preventDefault();if(!uploading)drop.classList.add('over');});});
  ['dragleave','drop'].forEach(function(e){drop.addEventListener(e,function(ev){ev.preventDefault();drop.classList.remove('over');});});
  drop.addEventListener('drop',function(ev){addFiles(ev.dataTransfer.files);});
  clearBtn.addEventListener('click',function(){if(!uploading){queued=[];renderQueue();}});

  function uploadOne(item,bundleId,done){
    item.status='up';renderQueue();
    var fd=new FormData();
    var relName=item.file.webkitRelativePath || item.file.name;
    fd.append('file',item.file,relName);
    var xhr=new XMLHttpRequest();
    var url='/upload?target='+encodeURIComponent(target);
    if(bundleId)url+='&bundle='+encodeURIComponent(bundleId);
    xhr.open('POST',url,true);
    xhr.upload.onprogress=function(e){if(e.lengthComputable){bar.style.width=((e.loaded/e.total)*100)+'%';}};
    xhr.onload=function(){
      var ok=false,msg='';try{var r=JSON.parse(xhr.responseText);ok=r.ok;msg=r.msg||'';}catch(_){}
      if(ok){item.status='ok';}
      else{item.status='err';toast(relName+' error: '+(msg||xhr.status),'err');}
      renderQueue();done();
    };
    xhr.onerror=function(){item.status='err';toast(relName+' connection error','err');renderQueue();done();};
    xhr.send(fd);
  }
  upBtn.addEventListener('click',function(){
    var todo=queued.filter(function(q){return q.status!=='ok';});
    if(!todo.length || uploading)return;
    // >1 file: auto-bundle so the receiver sees one package instead of N rows
    var bundleId=(todo.length>1) ? randomHex(8) : null;
    uploading=true;renderQueue();barWrap.classList.add('show');bar.style.width='0';
    if(bundleId)toast('Sending '+todo.length+' files as one bundle...','info');
    var i=0;
    (function next(){
      if(i>=todo.length){
        bar.style.width='100%';
        var okN=queued.filter(function(q){return q.status==='ok';}).length;
        if(bundleId)toast('Bundle sent ('+okN+' files)','ok');
        else toast(okN+' file(s) sent','ok');
        setTimeout(function(){uploading=false;renderQueue();fetchState();bar.style.width='0';barWrap.classList.remove('show');},700);
        return;
      }
      bar.style.width='0';
      uploadOne(todo[i],bundleId,function(){i++;next();});
    })();
  });

  fetchState();
  setInterval(fetchState,4000);
  window.addEventListener('focus',fetchState);
</script>
</body></html>
"@
}

# ============================== ROUTER ========================================
function Invoke-RequestRouter {
    param($Req, [System.IO.Stream]$Stream)
    $path = $Req.Path; $method = $Req.Method

    switch ($path) {

        '/' {
            if ($method -eq 'POST') {
                $bodyText = [System.Text.Encoding]::UTF8.GetString($Req.Body)
                $form = [System.Web.HttpUtility]::ParseQueryString($bodyText)
                $pw = $form['password']
                if ($pw -eq $Global:Password) {
                    $sid = New-SessionId
                    $pub = New-ShortId 4
                    $providedNick = $form['nick']
                    if ($providedNick) { $providedNick = $providedNick.Trim() }
                    $nick = if ($providedNick) { $providedNick } else { Get-DeviceLabel -UA $Req.UserAgent -IP $Req.ClientIp }
                    if ($nick.Length -gt 32) { $nick = $nick.Substring(0,32) }
                    $now = Get-Date
                    $Global:Sessions[$sid] = @{
                        Sid=$sid; PubId=$pub; Nick=$nick
                        IP=$Req.ClientIp; UA=$Req.UserAgent
                        Created=$now; LastSeen=$now
                    }
                    $Global:PubIndex[$pub] = $sid
                    $cookie = New-SessionCookieHeader -Sid $sid
                    Send-RedirectResponse -Stream $Stream -Location '/dashboard' -ExtraHeaders @{ 'Set-Cookie' = $cookie }
                } else {
                    Send-HtmlResponse -Stream $Stream -Html (Get-LoginPage -Error $true) -Status 401
                }
            } else {
                $sid = Test-ValidSession -Req $Req
                if ($sid) { Send-RedirectResponse -Stream $Stream -Location '/dashboard' }
                else { Send-HtmlResponse -Stream $Stream -Html (Get-LoginPage -Error $false) }
            }
        }

        '/dashboard' {
            $sid = Test-ValidSession -Req $Req
            if (-not $sid) { Send-RedirectResponse -Stream $Stream -Location '/'; return }
            Send-HtmlResponse -Stream $Stream -Html (Get-DashboardPage)
        }

        '/api/state' {
            $sid = Test-ValidSession -Req $Req
            if (-not $sid) { Send-JsonResponse -Stream $Stream -Json '{"ok":false}' -Status 401; return }
            $json = Get-StateJson -Sid $sid
            Send-JsonResponse -Stream $Stream -Json $json -Status 200
        }

        '/api/nick' {
            $sid = Test-ValidSession -Req $Req
            if (-not $sid) { Send-JsonResponse -Stream $Stream -Json '{"ok":false}' -Status 401; return }
            if ($method -ne 'POST') { Send-JsonResponse -Stream $Stream -Json '{"ok":false}' -Status 405; return }
            $nick = $null
            if ($Req.ContentType -match 'multipart/form-data') {
                $nick = Get-MultipartField -BodyBytes $Req.Body -ContentType $Req.ContentType -FieldName 'nick'
            } else {
                $bt = [System.Text.Encoding]::UTF8.GetString($Req.Body)
                $form = [System.Web.HttpUtility]::ParseQueryString($bt)
                $nick = $form['nick']
            }
            if ([string]::IsNullOrWhiteSpace($nick)) { Send-JsonResponse -Stream $Stream -Json '{"ok":false,"msg":"empty"}' -Status 400; return }
            $nick = $nick.Trim(); if ($nick.Length -gt 32) { $nick = $nick.Substring(0,32) }
            $Global:Sessions[$sid].Nick = $nick
            Send-JsonResponse -Stream $Stream -Json '{"ok":true}' -Status 200
        }

        '/api/delete' {
            $sid = Test-ValidSession -Req $Req
            if (-not $sid) { Send-JsonResponse -Stream $Stream -Json '{"ok":false}' -Status 401; return }
            if ($method -ne 'POST') { Send-JsonResponse -Stream $Stream -Json '{"ok":false}' -Status 405; return }
            $id = $null; $bundle = $null
            if ($Req.ContentType -match 'multipart/form-data') {
                $id     = Get-MultipartField -BodyBytes $Req.Body -ContentType $Req.ContentType -FieldName 'id'
                $bundle = Get-MultipartField -BodyBytes $Req.Body -ContentType $Req.ContentType -FieldName 'bundle'
            } else {
                $bt = [System.Text.Encoding]::UTF8.GetString($Req.Body)
                $form = [System.Web.HttpUtility]::ParseQueryString($bt)
                $id = $form['id']
                $bundle = $form['bundle']
            }
            if (-not [string]::IsNullOrWhiteSpace($bundle)) {
                $toDelete = @()
                foreach ($k in @($Global:Transfers.Keys)) {
                    $t = $Global:Transfers[$k]
                    if ($t -and $t.BundleId -eq $bundle -and $t.Sender -eq $sid) { $toDelete += $k }
                }
                if ($toDelete.Count -eq 0) { Send-JsonResponse -Stream $Stream -Json '{"ok":false,"msg":"not found"}' -Status 404; return }
                foreach ($tid in $toDelete) { [void](Remove-Transfer -Id $tid) }
                Send-JsonResponse -Stream $Stream -Json ('{"ok":true,"deleted":' + $toDelete.Count + '}') -Status 200
                return
            }
            if ([string]::IsNullOrWhiteSpace($id) -or -not $Global:Transfers.ContainsKey($id)) {
                Send-JsonResponse -Stream $Stream -Json '{"ok":false,"msg":"not found"}' -Status 404; return
            }
            $t = $Global:Transfers[$id]
            if ($t.Sender -ne $sid) { Send-JsonResponse -Stream $Stream -Json '{"ok":false,"msg":"forbidden"}' -Status 403; return }
            [void](Remove-Transfer -Id $id)
            Send-JsonResponse -Stream $Stream -Json '{"ok":true}' -Status 200
        }

        '/download' {
            $sid = Test-ValidSession -Req $Req
            if (-not $sid) { Send-RedirectResponse -Stream $Stream -Location '/'; return }
            Send-FileDownload -Req $Req -Stream $Stream -Sid $sid
        }

        '/api/zip' {
            $sid = Test-ValidSession -Req $Req
            if (-not $sid) { Send-HtmlResponse -Stream $Stream -Html '<h1>401 - sign in required</h1>' -Status 401; return }
            if ($method -ne 'POST') { Send-HtmlResponse -Stream $Stream -Html '<h1>405</h1>' -Status 405; return }
            $bodyText = [System.Text.Encoding]::UTF8.GetString($Req.Body)
            $form = [System.Web.HttpUtility]::ParseQueryString($bodyText)
            $collected = New-Object System.Collections.Generic.List[string]
            $rawIds = $form.GetValues('id')
            if ($rawIds) { foreach ($x in $rawIds) { if ($x) { [void]$collected.Add($x) } } }
            $rawBundles = $form.GetValues('bundle')
            if ($rawBundles) {
                foreach ($bid in $rawBundles) {
                    if (-not $bid) { continue }
                    foreach ($k in @($Global:Transfers.Keys)) {
                        $t = $Global:Transfers[$k]
                        if ($t -and $t.BundleId -eq $bid) { [void]$collected.Add($t.Id) }
                    }
                }
            }
            $ids = @($collected | Select-Object -Unique)
            if ($ids.Count -eq 0) { Send-HtmlResponse -Stream $Stream -Html '<h1>400 - no ids</h1>' -Status 400; return }
            Send-ZipDownload -Ids $ids -Sid $sid -Stream $Stream
        }

        '/upload' {
            $sid = Test-ValidSession -Req $Req
            if (-not $sid) { Send-JsonResponse -Stream $Stream -Json '{"ok":false,"msg":"no session"}' -Status 401; return }
            if ($method -ne 'POST') { Send-JsonResponse -Stream $Stream -Json '{"ok":false,"msg":"POST required"}' -Status 405; return }
            $q = [System.Web.HttpUtility]::ParseQueryString($Req.Query)
            $targetParam = $q['target']
            $targetSid = Resolve-TargetSid -TargetParam $targetParam
            if ($null -eq $targetSid) { Send-JsonResponse -Stream $Stream -Json '{"ok":false,"msg":"invalid target"}' -Status 400; return }
            $bundleParam = $q['bundle']
            if ($bundleParam) { $bundleParam = ($bundleParam -replace '[^a-zA-Z0-9]', '') }
            $r = Save-UploadedFileStream -NetStream $Stream -ContentType $Req.ContentType -SenderSid $sid -Target $targetSid -BundleId $bundleParam
            if ($r.ok) {
                Send-JsonResponse -Stream $Stream -Json (('{"ok":true,"id":"' + $r.id + '","msg":"' + ($r.msg -replace '"',"'") + '"}'))
            } else {
                $msg = ($r.msg -replace '"', "'")
                Send-JsonResponse -Stream $Stream -Json ('{"ok":false,"msg":"' + $msg + '"}') -Status $r.status
            }
        }

        '/logout' {
            $sid = $Req.Cookies[$Global:CookieName]
            if ($sid -and $Global:Sessions.ContainsKey($sid)) {
                $pub = $Global:Sessions[$sid].PubId
                if ($pub) { [void]$Global:PubIndex.Remove($pub) }
                [void]$Global:Sessions.Remove($sid)
            }
            $cookie = New-SessionCookieHeader -Sid '' -Expire $true
            Send-RedirectResponse -Stream $Stream -Location '/' -ExtraHeaders @{ 'Set-Cookie' = $cookie }
        }

        default {
            Send-HtmlResponse -Stream $Stream -Html '<h1>404</h1>' -Status 404
        }
    }
}

# ============================== NETWORK SETUP ================================
function Get-WifiInterface {
    try {
        $wifiAdapters = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object {
            $_.Status -eq 'Up' -and (
                $_.PhysicalMediaType -match '802\.11' -or
                $_.NdisPhysicalMedium -eq 'Native802_11' -or
                $_.Name -match 'Wi-?Fi|Wireless|WLAN' -or
                $_.InterfaceDescription -match 'Wireless|Wi-?Fi|802\.11'
            )
        }
        $candidates = @()
        foreach ($a in $wifiAdapters) {
            $ips = Get-NetIPAddress -AddressFamily IPv4 -InterfaceIndex $a.ifIndex -ErrorAction SilentlyContinue |
                   Where-Object { $_.IPAddress -ne '127.0.0.1' -and $_.IPAddress -notlike '169.254.*' }
            foreach ($ip in $ips) {
                $candidates += @{ IP = $ip.IPAddress; Prefix = $ip.PrefixLength; Name = $a.Name; Hotspot = ($ip.IPAddress -like '192.168.137.*') }
            }
        }
        if ($candidates.Count -gt 0) {
            $hot = $candidates | Where-Object { $_.Hotspot } | Select-Object -First 1
            if ($hot) { return $hot }
            return ($candidates | Select-Object -First 1)
        }
    } catch {}
    return $null
}

function Test-SameSubnet {
    param([string]$ClientIp, [string]$LocalIp, [int]$Prefix)
    try {
        $c = [System.Net.IPAddress]::Parse($ClientIp).GetAddressBytes()
        $l = [System.Net.IPAddress]::Parse($LocalIp).GetAddressBytes()
        if ($c.Length -ne $l.Length) { return $false }
        $bits = $Prefix
        for ($i = 0; $i -lt $c.Length; $i++) {
            $take = [Math]::Min(8, $bits)
            if ($take -le 0) { break }
            $mask = [byte](0xFF -shl (8 - $take))
            if (($c[$i] -band $mask) -ne ($l[$i] -band $mask)) { return $false }
            $bits -= 8
        }
        return $true
    } catch { return $false }
}

function Show-StartupBanner {
    param([hashtable]$Wifi)
    $logo = @"

   __    ____    ____    ___    ____  _____  __    __
  / /   |  _ \  |  _ \  / _ \  |  _ \|_   _| \ \  / /
 | |    | | | | | |_) || | | | | |_) | | |    \ \/ /
 | |___ | |_| | |  __/ | |_| | |  _ <  | |     |  |
 |_____||____/  |_|     \___/  |_| \_\ |_|     |__|

      L O C A L   F I L E   P O R T A L   v2.0
            Bidirectional Wi-Fi Transfer
"@
    Write-Host $logo -ForegroundColor Cyan

    $url = "http://$($Wifi.IP):$($Global:Port)/"
    Write-Host ''
    Write-Host '  +--------------------------------------------------------+' -ForegroundColor DarkGray
    Write-Host ('  |  URL          : {0,-38} |' -f $url)                                  -ForegroundColor Green
    Write-Host ('  |  Wi-Fi Adapter: {0,-38} |' -f $Wifi.Name)                            -ForegroundColor Gray
    Write-Host ('  |  Subnet       : {0,-38} |' -f ("$($Wifi.IP)/$($Wifi.Prefix)"))       -ForegroundColor Gray
    Write-Host ('  |  Time Limit   : {0,-38} |' -f 'NONE (1 year)')                       -ForegroundColor Gray
    Write-Host ('  |  Size Limit   : {0,-38} |' -f 'NONE')                                -ForegroundColor Gray
    Write-Host ('  |  Folder       : {0,-38} |' -f $Global:ShareFolder)                   -ForegroundColor Gray
    Write-Host ('  |  Concurrency  : {0,-38} |' -f ("$($Global:MaxThreads) threads"))     -ForegroundColor Gray
    Write-Host ('  |  Password     : {0,-38} |' -f $Global:Password)                      -ForegroundColor Magenta
    Write-Host '  +--------------------------------------------------------+' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  [Wi-Fi only] Only Wi-Fi IP allowed, LAN clients rejected.' -ForegroundColor Green
    if ($Wifi.Hotspot) { Write-Host '  [Hotspot] Mobile Hotspot network (192.168.137.x).' -ForegroundColor Green }
    Write-Host '  [Bidirectional] Device-to-device private + public broadcast.' -ForegroundColor Green
    Write-Host '  [No admin] TcpListener. Press Ctrl+C to stop.' -ForegroundColor DarkGray
    Write-Host ''
}

# ============================== MAIN LOOP ====================================
$wifi = Get-WifiInterface
if ($null -eq $wifi) {
    Write-Host ''
    Write-Host '  [ERROR] No active Wi-Fi (wireless) connection found.' -ForegroundColor Red
    Write-Host '  This portal only allows sharing over Wi-Fi.' -ForegroundColor Yellow
    Write-Host '  Connect to a Wi-Fi network or enable Mobile Hotspot, then retry.' -ForegroundColor Yellow
    Write-Host ''
    return
}

# Restart-safe: load transfer records from disk
Import-AllTransfers

$bindAddr = [System.Net.IPAddress]::Parse($wifi.IP)
$listener = New-Object System.Net.Sockets.TcpListener($bindAddr, $Global:Port)

try {
    $listener.Start()
} catch {
    Write-Host ''
    Write-Host '  [ERROR] Failed to start listener.' -ForegroundColor Red
    Write-Host "  Message: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  Port $($Global:Port) may be in use by another application." -ForegroundColor Yellow
    Write-Host '  Check: netstat -ano | findstr :8080' -ForegroundColor Cyan
    Write-Host ''
    return
}

Show-StartupBanner -Wifi $wifi
Write-Host ("  Worker threads: {0} | Loaded transfers: {1}" -f $Global:MaxThreads, $Global:Transfers.Count) -ForegroundColor Green
Write-Host ''

# Auto-open the portal in the default browser
try {
    $startUrl = "http://$($wifi.IP):$($Global:Port)/"
    Start-Process $startUrl -ErrorAction Stop | Out-Null
    Write-Host ('  [Browser] Opened {0}' -f $startUrl) -ForegroundColor DarkGray
    Write-Host ''
} catch {
    Write-Host '  [Browser] Auto-open failed; open the URL manually.' -ForegroundColor DarkYellow
    Write-Host ''
}

# ====================== RUNSPACE POOL ========================================
$iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
$iss.ApartmentState = 'MTA'

$funcNames = @(
    'Get-IconForFile','Format-Size','New-SessionId','New-ShortId','Get-DeviceLabel',
    'Invoke-PeriodicSweep','Save-TransferMeta','Remove-Transfer','ConvertTo-SafeRelPath',
    'Read-HttpRequest','Read-RequestBody','Get-HttpStatusText','Send-Response',
    'Send-HtmlResponse','Send-JsonResponse','Send-RedirectResponse','New-SessionCookieHeader',
    'Test-ValidSession','Resolve-TargetSid','Get-MultipartField',
    'Save-UploadedFileStream','Send-FileDownload','Send-ZipDownload','Get-StateJson',
    'Get-LoginPage','Get-DashboardPage','Invoke-RequestRouter'
)
foreach ($fn in $funcNames) {
    $def = (Get-Command $fn -CommandType Function).Definition
    $iss.Commands.Add((New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry($fn, $def)))
}

$sharedVars = @{
    Password    = $Global:Password
    Port        = $Global:Port
    ShareFolder = $Global:ShareFolder
    MetaFolder  = $Global:MetaFolder
    CookieName  = $Global:CookieName
    SessionTTL  = $Global:SessionTTL
    DeviceTTL   = $Global:DeviceTTL
    SweepEvery  = $Global:SweepEvery
    Sessions    = $Global:Sessions
    PubIndex    = $Global:PubIndex
    Transfers   = $Global:Transfers
    UploadLock  = $Global:UploadLock
    SweepState  = $Global:SweepState
}
foreach ($k in $sharedVars.Keys) {
    $iss.Variables.Add((New-Object System.Management.Automation.Runspaces.SessionStateVariableEntry($k, $sharedVars[$k], '')))
}

$pool = [runspacefactory]::CreateRunspacePool(1, $Global:MaxThreads, $iss, $Host)
$pool.Open()

$worker = {
    param($client, $ts, $remoteIp)
    Add-Type -AssemblyName System.Web
    $stream = $null
    try {
        $client.NoDelay = $true
        $client.SendTimeout    = 600000
        $client.ReceiveTimeout = 600000
        $stream = $client.GetStream()
        $stream.ReadTimeout  = 600000
        $stream.WriteTimeout = 600000

        $req = Read-HttpRequest -Stream $stream
        if ($null -eq $req) { return }
        $req.ClientIp = $remoteIp

        Write-Host ("[{0}] {1,-6} {2,-30} <- {3}" -f $ts, $req.Method, $req.RawTarget, $remoteIp) -ForegroundColor DarkGray

        $isUpload = ($req.Method -eq 'POST' -and $req.Path -eq '/upload')
        if (-not $isUpload) {
            if ($req.ContentLength -gt 0) {
                $req.Body = Read-RequestBody -Stream $stream -Length $req.ContentLength
            } else {
                $req.Body = New-Object byte[] 0
            }
        }

        Invoke-RequestRouter -Req $req -Stream $stream
    } catch {
        try { if ($stream) { Send-HtmlResponse -Stream $stream -Html '<h1>500</h1>' -Status 500 } } catch {}
    } finally {
        try { if ($stream) { $stream.Close() } } catch {}
        try { $client.Close() } catch {}
    }
}

$jobs = New-Object System.Collections.ArrayList

try {
    while ($true) {
        $client = $listener.AcceptTcpClient()
        $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')

        $remoteIp = $null
        try { $remoteIp = $client.Client.RemoteEndPoint.Address.ToString() } catch {}
        if ($remoteIp -and $remoteIp -ne $wifi.IP -and -not (Test-SameSubnet -ClientIp $remoteIp -LocalIp $wifi.IP -Prefix $wifi.Prefix)) {
            Write-Host ("[{0}] DENY  Non-Wi-Fi client rejected: {1}" -f $ts, $remoteIp) -ForegroundColor Yellow
            try { $client.Close() } catch {}
            continue
        }

        $ps = [powershell]::Create()
        $ps.RunspacePool = $pool
        [void]$ps.AddScript($worker).AddArgument($client).AddArgument($ts).AddArgument($remoteIp)
        $handle = $ps.BeginInvoke()
        [void]$jobs.Add([pscustomobject]@{ PS = $ps; Handle = $handle })

        for ($i = $jobs.Count - 1; $i -ge 0; $i--) {
            if ($jobs[$i].Handle.IsCompleted) {
                try { $jobs[$i].PS.EndInvoke($jobs[$i].Handle) } catch {}
                try { $jobs[$i].PS.Dispose() } catch {}
                $jobs.RemoveAt($i)
            }
        }
    }
} finally {
    try { $listener.Stop() } catch {}
    foreach ($j in $jobs) { try { $j.PS.Dispose() } catch {} }
    try { $pool.Close(); $pool.Dispose() } catch {}
    Write-Host ''
    Write-Host '  Server stopped.' -ForegroundColor Yellow
}

# ==============================================================================
# RUN (NO ADMIN REQUIRED):
#   powershell.exe -ExecutionPolicy Bypass -File LocalFilePortal.ps1
#
# FEATURES:
#   - Wi-Fi only (LAN denied; two checks: bind + subnet)
#   - Connected devices listed (all signed-in clients); click-to-target send
#   - "Everyone (Public)" card broadcasts to every device
#   - No size limit, no session expiry
#   - Streaming multipart parser + C# FastScan boundary (fast)
#   - 32-thread runspace pool, concurrent up/down
#   - Restart-safe transfers (.meta\<id>.json)
#   - Device name picked at login, editable from dashboard
#
# STORAGE:
#   - Files: $Global:ShareFolder (default C:\SharedTransfer)
#   - Metadata sidecar: $ShareFolder\.meta\<id>.json (sender, target, ...)
#
# CONNECTING:
#   1. Other device must be on the SAME Wi-Fi (or Mobile Hotspot)
#   2. Open the URL from the console banner, password: hako123
#   3. After login: click a device card to send, or use Public to broadcast
#
# FIREWALL: On first request Windows may ask to allow -> tick "Private networks"
# ==============================================================================
