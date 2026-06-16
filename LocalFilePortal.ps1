# ==============================================================================
#  LocalFilePortal.ps1  -  Parola Korumali Yerel Web Dosya Sunucusu (Captive Portal)
#  Native PowerShell 5.1+  |  Harici bagimlilik YOK  |  Tek dosya
#  ADMIN GEREKTIRMEZ  -  TcpListener (port 8080) ile dinler, ayni Wi-Fi/LAN paylasimi
# ==============================================================================

Add-Type -AssemblyName System.Web

# ------------------------------------------------------------------------------
#  AYARLAR
# ------------------------------------------------------------------------------
$Global:Password      = 'hako123'
$Global:Port          = 8080
$Global:ShareFolder   = 'C:\SharedTransfer'
$Global:CookieName    = 'LDSID'
$Global:SessionTTL    = [TimeSpan]::FromHours(1)
$Global:MaxThreads    = 16    # ayni anda islenebilecek istek sayisi (es zamanli kullanici)
# Es zamanli erisim icin thread-safe: birden fazla worker ayni anda okur/yazar
$Global:Sessions      = [hashtable]::Synchronized(@{})   # SessionID -> @{ Created; LastSeen }
$Global:UploadLock    = New-Object object                # upload isim cakismasi kilidi

# Paylasim klasoru yoksa olustur
if (-not (Test-Path -LiteralPath $Global:ShareFolder)) {
    New-Item -ItemType Directory -Path $Global:ShareFolder -Force | Out-Null
}

# ------------------------------------------------------------------------------
#  YARDIMCI FONKSIYONLAR
# ------------------------------------------------------------------------------
function Get-IconForFile {
    param([string]$Name)
    $ext = [System.IO.Path]::GetExtension($Name).ToLowerInvariant().TrimStart('.')
    switch ($ext) {
        'pdf'                                   { return [char]0xD83D + [char]0xDCC4 } # PDF
        { $_ -in 'zip','rar','7z','tar','gz' }  { return [char]0xD83D + [char]0xDDDC } # ZIP
        { $_ -in 'jpg','jpeg','png','gif','bmp','webp','svg','tiff' } { return [char]0xD83D + [char]0xDDBC } # IMG
        { $_ -in 'mp4','mkv','avi','mov','wmv','flv','webm' }         { return [char]0xD83C + [char]0xDFAC } # VID
        { $_ -in 'mp3','wav','flac','aac','ogg','m4a' }              { return [char]0xD83C + [char]0xDFB5 } # SES
        { $_ -in 'exe','msi','bat','cmd','ps1' }                     { return [char]0x2699 + [char]0xFE0F } # EXE
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

function Remove-ExpiredSessions {
    $now = Get-Date
    $dead = @()
    foreach ($k in @($Global:Sessions.Keys)) {
        if (($now - $Global:Sessions[$k].LastSeen) -gt $Global:SessionTTL) { $dead += $k }
    }
    foreach ($k in $dead) { $Global:Sessions.Remove($k) }
}

function New-SessionId {
    $bytes = New-Object byte[] 32
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return ([System.BitConverter]::ToString($bytes) -replace '-', '').ToLowerInvariant()
}

# ------------------------------------------------------------------------------
#  HTTP KATMANI (TcpListener uzerinde - admin gerektirmez)
# ------------------------------------------------------------------------------
# Request nesnesi: @{ Method; Path; Query; RawTarget; Headers(hash); Cookies(hash); Body([byte[]]); ContentType; ContentLength }

function Read-HttpRequest {
    param([System.IO.Stream]$Stream)

    # Header bloklarini \r\n\r\n gorene kadar byte byte oku
    $headerBytes = New-Object System.Collections.Generic.List[byte]
    $b0=-1;$b1=-1;$b2=-1;$b3=-1
    while ($true) {
        $b = $Stream.ReadByte()
        if ($b -lt 0) { break }
        $headerBytes.Add([byte]$b)
        $b0=$b1; $b1=$b2; $b2=$b3; $b3=$b
        if ($b0 -eq 13 -and $b1 -eq 10 -and $b2 -eq 13 -and $b3 -eq 10) { break }
        if ($headerBytes.Count -gt 65536) { break }  # asiri header korumasi
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

    # Cookies
    $cookies = @{}
    if ($headers.ContainsKey('cookie')) {
        foreach ($pair in $headers['cookie'].Split(';')) {
            $kv = $pair.Trim()
            $ei = $kv.IndexOf('=')
            if ($ei -gt 0) { $cookies[$kv.Substring(0,$ei).Trim()] = $kv.Substring($ei+1).Trim() }
        }
    }

    $contentLength = 0
    if ($headers.ContainsKey('content-length')) { [void][int64]::TryParse($headers['content-length'], [ref]$contentLength) }
    $contentType = ''
    if ($headers.ContainsKey('content-type')) { $contentType = $headers['content-type'] }

    return [pscustomobject]@{
        Method        = $method
        Path          = $path.ToLowerInvariant()
        RawTarget     = $rawTarget
        Query         = $query
        Headers       = $headers
        Cookies       = $cookies
        ContentLength = $contentLength
        ContentType   = $contentType
        Stream        = $Stream
        Body          = $null
    }
}

function Read-RequestBody {
    param([System.IO.Stream]$Stream, [int64]$Length)
    if ($Length -le 0) { return New-Object byte[] 0 }
    $buf = New-Object byte[] $Length
    $got = 0
    while ($got -lt $Length) {
        $r = $Stream.Read($buf, $got, [int][Math]::Min(81920, $Length - $got))
        if ($r -le 0) { break }
        $got += $r
    }
    if ($got -lt $Length) {
        $trim = New-Object byte[] $got
        [System.Array]::Copy($buf, 0, $trim, 0, $got)
        return $trim
    }
    return $buf
}

function Get-HttpStatusText {
    param([int]$Code)
    switch ($Code) {
        200 { 'OK' } 302 { 'Found' } 400 { 'Bad Request' } 401 { 'Unauthorized' }
        403 { 'Forbidden' } 404 { 'Not Found' } 405 { 'Method Not Allowed' }
        413 { 'Payload Too Large' } 500 { 'Internal Server Error' } default { 'OK' }
    }
}

function Send-Response {
    param(
        [System.IO.Stream]$Stream,
        [int]$Status = 200,
        [string]$ContentType = 'text/html; charset=utf-8',
        [byte[]]$Body = $null,
        [hashtable]$ExtraHeaders = $null
    )
    if ($null -eq $Body) { $Body = New-Object byte[] 0 }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("HTTP/1.1 $Status " + (Get-HttpStatusText $Status) + "`r`n")
    [void]$sb.Append("Content-Type: $ContentType`r`n")
    [void]$sb.Append("Content-Length: $($Body.Length)`r`n")
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
    $buf = [System.Text.Encoding]::UTF8.GetBytes($Html)
    Send-Response -Stream $Stream -Status $Status -ContentType 'text/html; charset=utf-8' -Body $buf -ExtraHeaders $ExtraHeaders
}

function Send-JsonResponse {
    param([System.IO.Stream]$Stream, [string]$Json, [int]$Status = 200, [hashtable]$ExtraHeaders = $null)
    $buf = [System.Text.Encoding]::UTF8.GetBytes($Json)
    Send-Response -Stream $Stream -Status $Status -ContentType 'application/json; charset=utf-8' -Body $buf -ExtraHeaders $ExtraHeaders
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
        $exp = 'Thu, 01 Jan 1970 00:00:00 GMT'
        return "$Global:CookieName=deleted; Path=/; HttpOnly; SameSite=Strict; Expires=$exp"
    }
    $exp = (Get-Date).Add($Global:SessionTTL).ToUniversalTime().ToString('R')
    return "$Global:CookieName=$Sid; Path=/; HttpOnly; SameSite=Strict; Expires=$exp"
}

function Test-ValidSession {
    param($Req)
    Remove-ExpiredSessions
    $sid = $Req.Cookies[$Global:CookieName]
    if ($sid -and $Global:Sessions.ContainsKey($sid)) {
        $Global:Sessions[$sid].LastSeen = Get-Date
        return $true
    }
    return $false
}

# ------------------------------------------------------------------------------
#  HTML SAYFALARI
# ------------------------------------------------------------------------------
function Get-LoginPage {
    param([bool]$Error = $false)
    $errBlock = if ($Error) { '<div class="error-msg">Hatali parola. Tekrar deneyin.</div>' } else { '' }
    return @"
<!DOCTYPE html>
<html lang="tr">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Yerel Dosya Portali - Giris</title>
<style>
  :root{
    --bg:#0d0f12; --card:#141720; --border:#1e2330; --accent:#4f8ef7;
    --text:#e8ecf5; --muted:#5a6480; --ok:#4ff78e; --err:#f74f6a;
  }
  *{box-sizing:border-box;margin:0;padding:0}
  body{
    font-family:'Segoe UI',system-ui,sans-serif;background:var(--bg);color:var(--text);
    min-height:100vh;display:flex;align-items:center;justify-content:center;overflow:hidden;
  }
  .grid-bg{
    position:fixed;inset:0;z-index:0;
    background-image:linear-gradient(rgba(79,142,247,.07) 1px,transparent 1px),
                     linear-gradient(90deg,rgba(79,142,247,.07) 1px,transparent 1px);
    background-size:42px 42px;animation:drift 22s linear infinite;
  }
  @keyframes drift{from{background-position:0 0}to{background-position:42px 42px}}
  .card{
    position:relative;z-index:1;background:var(--card);border:1px solid var(--border);
    border-radius:18px;padding:42px 38px;width:380px;max-width:92vw;
    box-shadow:0 24px 60px rgba(0,0,0,.55);
  }
  .logo{display:flex;align-items:center;gap:12px;margin-bottom:6px}
  .logo .icon{font-size:34px}
  .logo h1{font-size:20px;font-weight:700;letter-spacing:.5px}
  .sub{color:var(--muted);font-size:13px;margin-bottom:26px}
  label{display:block;font-size:12px;color:var(--muted);margin-bottom:8px;text-transform:uppercase;letter-spacing:1px}
  .pw-wrap{position:relative;margin-bottom:18px}
  input[type=password],input[type=text].pw{
    width:100%;padding:13px 46px 13px 14px;background:var(--bg);border:1px solid var(--border);
    border-radius:10px;color:var(--text);font-size:15px;outline:none;transition:border .2s;
  }
  input:focus{border-color:var(--accent)}
  .toggle{
    position:absolute;right:8px;top:50%;transform:translateY(-50%);background:none;border:none;
    color:var(--muted);cursor:pointer;font-size:18px;padding:6px;
  }
  button.submit{
    width:100%;padding:13px;background:var(--accent);color:#fff;border:none;border-radius:10px;
    font-size:15px;font-weight:600;cursor:pointer;transition:filter .2s;
  }
  button.submit:hover{filter:brightness(1.1)}
  .error-msg{
    background:rgba(247,79,106,.12);border:1px solid var(--err);color:var(--err);
    padding:10px 12px;border-radius:8px;font-size:13px;margin-bottom:18px;
  }
  .status{display:flex;align-items:center;gap:8px;margin-top:22px;font-size:12px;color:var(--muted);justify-content:center}
  .dot{width:9px;height:9px;border-radius:50%;background:var(--ok);box-shadow:0 0 8px var(--ok);animation:blink 1.4s ease-in-out infinite}
  @keyframes blink{0%,100%{opacity:1}50%{opacity:.25}}
</style>
</head>
<body>
  <div class="grid-bg"></div>
  <div class="card">
    <div class="logo"><span class="icon">&#128274;</span><h1>YEREL DOSYA PORTALI</h1></div>
    <div class="sub">Devam etmek icin erisim parolasini girin.</div>
    $errBlock
    <form method="POST" action="/">
      <label for="pw">Parola</label>
      <div class="pw-wrap">
        <input id="pw" name="password" type="password" placeholder="&#8226;&#8226;&#8226;&#8226;&#8226;&#8226;" autofocus required>
        <button type="button" class="toggle" id="tgl" title="Goster/Gizle">&#128065;</button>
      </div>
      <button type="submit" class="submit">Giris Yap</button>
    </form>
    <div class="status"><span class="dot"></span> Sunucu aktif - dinleniyor</div>
  </div>
<script>
  var pw=document.getElementById('pw'),tgl=document.getElementById('tgl');
  tgl.addEventListener('click',function(){
    if(pw.type==='password'){pw.type='text';tgl.style.color='#4f8ef7';}
    else{pw.type='password';tgl.style.color='';}
  });
</script>
</body>
</html>
"@
}

function Get-DashboardPage {
    $files = @(Get-ChildItem -LiteralPath $Global:ShareFolder -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    $count = $files.Count
    $total = ($files | Measure-Object -Property Length -Sum).Sum
    if (-not $total) { $total = 0 }
    $totalStr = Format-Size $total

    if ($count -eq 0) {
        $rows = '<tr><td colspan="5" class="empty">&#128230; Henuz dosya yok. Asagidan dosya yukleyin.</td></tr>'
    } else {
        $sb = New-Object System.Text.StringBuilder
        foreach ($f in $files) {
            $icon = Get-IconForFile $f.Name
            $size = Format-Size $f.Length
            $date = $f.LastWriteTime.ToString('dd.MM.yyyy HH:mm')
            $nameEnc = [System.Web.HttpUtility]::UrlEncode($f.Name)
            $nameHtml = [System.Web.HttpUtility]::HtmlEncode($f.Name)
            [void]$sb.Append("<tr><td class='ic'>$icon</td><td class='nm'>$nameHtml</td><td>$size</td><td class='dt'>$date</td><td><a class='dl' href='/download?file=$nameEnc'>&#11015; Indir</a></td></tr>")
        }
        $rows = $sb.ToString()
    }

    return @"
<!DOCTYPE html>
<html lang="tr">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Yerel Dosya Portali - Panel</title>
<style>
  :root{
    --bg:#0d0f12; --card:#141720; --border:#1e2330; --accent:#4f8ef7;
    --text:#e8ecf5; --muted:#5a6480; --ok:#4ff78e; --err:#f74f6a;
  }
  *{box-sizing:border-box;margin:0;padding:0}
  body{font-family:'Segoe UI',system-ui,sans-serif;background:var(--bg);color:var(--text);min-height:100vh}
  header{
    position:sticky;top:0;z-index:10;background:rgba(20,23,32,.92);backdrop-filter:blur(8px);
    border-bottom:1px solid var(--border);padding:16px 28px;display:flex;align-items:center;justify-content:space-between;
  }
  .brand{display:flex;align-items:center;gap:11px}
  .brand .icon{font-size:26px}
  .brand h1{font-size:17px;letter-spacing:.5px}
  .stats{display:flex;gap:22px;align-items:center}
  .stat{font-size:13px;color:var(--muted)}
  .stat b{color:var(--text);font-weight:600}
  .logout{color:var(--err);text-decoration:none;font-size:13px;border:1px solid var(--border);padding:7px 14px;border-radius:8px;transition:background .2s}
  .logout:hover{background:rgba(247,79,106,.1)}
  .wrap{max-width:1000px;margin:0 auto;padding:28px}
  .panel{background:var(--card);border:1px solid var(--border);border-radius:14px;padding:22px;margin-bottom:24px}
  .panel h2{font-size:14px;text-transform:uppercase;letter-spacing:1px;color:var(--muted);margin-bottom:16px}
  table{width:100%;border-collapse:collapse}
  th{text-align:left;font-size:11px;text-transform:uppercase;letter-spacing:1px;color:var(--muted);padding:8px 10px;border-bottom:1px solid var(--border)}
  td{padding:11px 10px;border-bottom:1px solid var(--border);font-size:14px}
  td.ic{font-size:20px;width:40px}
  td.nm{word-break:break-all}
  td.dt{color:var(--muted);font-size:13px}
  tr:last-child td{border-bottom:none}
  tr:hover td{background:rgba(79,142,247,.04)}
  .dl{color:var(--accent);text-decoration:none;font-size:13px;white-space:nowrap}
  .dl:hover{text-decoration:underline}
  .empty{text-align:center;color:var(--muted);padding:34px;font-size:14px}
  .drop{
    border:2px dashed var(--border);border-radius:12px;padding:38px;text-align:center;
    color:var(--muted);cursor:pointer;transition:all .2s;
  }
  .drop.over{border-color:var(--accent);background:rgba(79,142,247,.06);color:var(--text)}
  .drop .big{font-size:38px;margin-bottom:10px}
  .filelist{display:flex;flex-direction:column;gap:8px;margin:16px 0 0}
  .fileitem{
    display:flex;align-items:center;gap:12px;padding:10px 14px;background:var(--bg);
    border:1px solid var(--border);border-radius:10px;font-size:13px;
  }
  .fileitem .fi-ic{font-size:18px}
  .fileitem .fi-name{flex:1;word-break:break-all}
  .fileitem .fi-size{color:var(--muted);font-size:12px;white-space:nowrap}
  .fileitem .fi-stat{font-size:12px;white-space:nowrap}
  .fileitem .fi-stat.ok{color:var(--ok)}
  .fileitem .fi-stat.err{color:var(--err)}
  .fileitem .fi-stat.up{color:var(--accent)}
  .fileitem .fi-x{cursor:pointer;color:var(--err);font-weight:700;padding:0 4px}
  .fileitem.toobig{border-color:var(--err)}
  .bar-wrap{display:none;margin-top:16px;background:var(--bg);border-radius:30px;overflow:hidden;height:10px;border:1px solid var(--border)}
  .bar-wrap.show{display:block}
  .bar{height:100%;width:0;background:var(--accent);transition:width .15s}
  .up-row{display:flex;align-items:center;gap:12px;margin-top:16px;flex-wrap:wrap}
  .btn{padding:11px 22px;background:var(--accent);color:#fff;border:none;border-radius:9px;font-size:14px;font-weight:600;cursor:pointer}
  .btn:disabled{opacity:.5;cursor:not-allowed}
  .btn.ghost{background:transparent;border:1px solid var(--border);color:var(--muted)}
  .btn.ghost:hover{color:var(--text)}
  .count-lbl{color:var(--muted);font-size:13px}
  .toast-box{position:fixed;right:22px;bottom:22px;z-index:50;display:flex;flex-direction:column;gap:10px}
  .toast{
    padding:13px 18px;border-radius:10px;font-size:13px;color:#fff;box-shadow:0 10px 30px rgba(0,0,0,.5);
    animation:slidein .25s ease;min-width:220px;
  }
  .toast.ok{background:#16321f;border:1px solid var(--ok);color:var(--ok)}
  .toast.err{background:#321016;border:1px solid var(--err);color:var(--err)}
  @keyframes slidein{from{transform:translateX(120%);opacity:0}to{transform:translateX(0);opacity:1}}
</style>
</head>
<body>
  <header>
    <div class="brand"><span class="icon">&#128193;</span><h1>YEREL DOSYA PORTALI</h1></div>
    <div class="stats">
      <span class="stat">Dosya: <b>$count</b></span>
      <span class="stat">Toplam: <b>$totalStr</b></span>
      <a class="logout" href="/logout">&#128682; Cikis Yap</a>
    </div>
  </header>
  <div class="wrap">
    <div class="panel">
      <h2>Dosyalar</h2>
      <table>
        <thead><tr><th></th><th>Dosya Adi</th><th>Boyut</th><th>Tarih</th><th></th></tr></thead>
        <tbody>$rows</tbody>
      </table>
    </div>
    <div class="panel">
      <h2>Dosya Yukle</h2>
      <div class="drop" id="drop">
        <div class="big">&#128228;</div>
        <div>Dosyalari buraya surukleyip birakin <br>veya tiklayarak <b>birden fazla</b> dosya secin</div>
        <input type="file" id="file" multiple hidden>
      </div>
      <div class="filelist" id="fileList"></div>
      <div class="bar-wrap" id="barWrap"><div class="bar" id="bar"></div></div>
      <div class="up-row">
        <button class="btn" id="upBtn" disabled>Tumunu Yukle</button>
        <button class="btn ghost" id="clearBtn">Temizle</button>
        <span class="count-lbl" id="countLbl"></span>
      </div>
    </div>
  </div>
  <div class="toast-box" id="toasts"></div>
<script>
  var drop=document.getElementById('drop'),fileInp=document.getElementById('file'),
      fileList=document.getElementById('fileList'),barWrap=document.getElementById('barWrap'),
      bar=document.getElementById('bar'),upBtn=document.getElementById('upBtn'),
      clearBtn=document.getElementById('clearBtn'),countLbl=document.getElementById('countLbl'),
      toasts=document.getElementById('toasts');
  var queued=[];          // {file, id, status} biriken liste
  var uploading=false;
  var seq=0;

  function toast(msg,type){
    var t=document.createElement('div');t.className='toast '+(type||'ok');t.textContent=msg;
    toasts.appendChild(t);
    setTimeout(function(){t.style.transition='opacity .3s';t.style.opacity='0';setTimeout(function(){t.remove();},300);},3500);
  }
  function fmtSize(b){
    if(b>=1073741824)return (b/1073741824).toFixed(2)+' GB';
    if(b>=1048576)return (b/1048576).toFixed(2)+' MB';
    if(b>=1024)return (b/1024).toFixed(2)+' KB';
    return b+' B';
  }
  function addFiles(list){
    if(uploading)return;
    Array.prototype.forEach.call(list,function(f){
      // ayni ad+boyut tekrar eklenmesin
      var dup=queued.some(function(q){return q.file.name===f.name && q.file.size===f.size;});
      if(!dup){queued.push({file:f,id:++seq,status:'wait'});}
    });
    render();
  }
  function removeItem(id){
    queued=queued.filter(function(q){return q.id!==id;});
    render();
  }
  function render(){
    fileList.innerHTML='';
    queued.forEach(function(q){
      var row=document.createElement('div');
      row.className='fileitem';
      var stat='';
      if(q.status==='ok'){stat='<span class="fi-stat ok">&#10003; yuklendi</span>';}
      else if(q.status==='err'){stat='<span class="fi-stat err">&#10007; hata</span>';}
      else if(q.status==='up'){stat='<span class="fi-stat up">yukleniyor...</span>';}
      var rm=(uploading?'':'<span class="fi-x" data-id="'+q.id+'">&#10005;</span>');
      row.innerHTML='<span class="fi-ic">&#128196;</span>'+
        '<span class="fi-name">'+q.file.name.replace(/</g,'&lt;')+'</span>'+
        '<span class="fi-size">'+fmtSize(q.file.size)+'</span>'+stat+rm;
      fileList.appendChild(row);
    });
    upBtn.disabled=(queued.length===0||uploading);
    clearBtn.style.display=(queued.length&&!uploading)?'inline-block':'none';
    countLbl.textContent=queued.length?(queued.length+' dosya secildi'):'';
  }
  fileList.addEventListener('click',function(ev){
    var x=ev.target.closest('.fi-x');
    if(x){removeItem(parseInt(x.getAttribute('data-id'),10));}
  });
  drop.addEventListener('click',function(){if(!uploading)fileInp.click();});
  fileInp.addEventListener('change',function(){addFiles(fileInp.files);fileInp.value='';});
  ['dragenter','dragover'].forEach(function(e){drop.addEventListener(e,function(ev){ev.preventDefault();if(!uploading)drop.classList.add('over');});});
  ['dragleave','drop'].forEach(function(e){drop.addEventListener(e,function(ev){ev.preventDefault();drop.classList.remove('over');});});
  drop.addEventListener('drop',function(ev){addFiles(ev.dataTransfer.files);});
  clearBtn.addEventListener('click',function(){if(!uploading){queued=[];render();}});

  function uploadOne(item,done){
    item.status='up';render();
    var fd=new FormData();fd.append('file',item.file,item.file.name);
    var xhr=new XMLHttpRequest();xhr.open('POST','/upload',true);
    xhr.upload.onprogress=function(e){if(e.lengthComputable){bar.style.width=((e.loaded/e.total)*100)+'%';}};
    xhr.onload=function(){
      var ok=false,msg='';
      try{var r=JSON.parse(xhr.responseText);ok=r.ok;msg=r.msg||'';}catch(_){}
      if(ok){item.status='ok';toast(item.file.name+' yuklendi','ok');}
      else{item.status='err';toast(item.file.name+' hata: '+(msg||xhr.status),'err');}
      render();done();
    };
    xhr.onerror=function(){item.status='err';toast(item.file.name+' baglanti hatasi','err');render();done();};
    xhr.send(fd);
  }
  upBtn.addEventListener('click',function(){
    var todo=queued.filter(function(q){return q.status!=='ok';});
    if(!todo.length||uploading)return;
    uploading=true;render();
    barWrap.classList.add('show');bar.style.width='0';
    var i=0;
    (function next(){
      if(i>=todo.length){
        bar.style.width='100%';
        var okCount=queued.filter(function(q){return q.status==='ok';}).length;
        toast(okCount+' dosya yuklendi','ok');
        setTimeout(function(){location.reload();},900);return;
      }
      bar.style.width='0';
      uploadOne(todo[i],function(){i++;next();});
    })();
  });
  render();
</script>
</body>
</html>
"@
}

# ------------------------------------------------------------------------------
#  MULTIPART PARSER (binary-safe, Latin1)
# ------------------------------------------------------------------------------
function Save-UploadedFileStream {
    # Streaming multipart parser: agi dogrudan diske akar, RAM'e tamamen yuklemez.
    # Boyut limiti yok. 256KB chunk ile agi diske esit hizda yazar.
    param([System.IO.Stream]$NetStream, [string]$ContentType)

    if ($ContentType -notmatch 'boundary=(.+)$') { return @{ ok=$false; status=400; msg='Boundary bulunamadi' } }
    $boundary = $Matches[1].Trim().Trim('"')
    $latin1   = [System.Text.Encoding]::GetEncoding(28591)

    # --- Adim 1: multipart header blogu oku (sadece ufak metin, ram'e alinir) ---
    $hdrBuf = New-Object System.Collections.Generic.List[byte]
    $b0=-1;$b1=-1;$b2=-1;$b3=-1
    while ($true) {
        $b = $NetStream.ReadByte()
        if ($b -lt 0) { return @{ ok=$false; status=400; msg='Baglanti kesildi (header)' } }
        $hdrBuf.Add([byte]$b)
        $b0=$b1; $b1=$b2; $b2=$b3; $b3=$b
        if ($b0 -eq 13 -and $b1 -eq 10 -and $b2 -eq 13 -and $b3 -eq 10) { break }
        if ($hdrBuf.Count -gt 8192) { return @{ ok=$false; status=400; msg='Multipart header cok buyuk' } }
    }
    $hdrText  = $latin1.GetString($hdrBuf.ToArray())
    $fileName = $null
    if ($hdrText -match 'filename="([^"]*)"') { $fileName = $Matches[1] }
    if ([string]::IsNullOrWhiteSpace($fileName)) { return @{ ok=$false; status=400; msg='Dosya adi yok' } }
    $fileName = [System.IO.Path]::GetFileName($fileName)

    # --- Adim 2: benzersiz dosya adi rezerve et (kisa kilit) ---
    $target = $null
    [System.Threading.Monitor]::Enter($Global:UploadLock)
    try {
        $target = Join-Path $ShareFolder $fileName
        if (Test-Path -LiteralPath $target) {
            $base = [System.IO.Path]::GetFileNameWithoutExtension($fileName)
            $ext  = [System.IO.Path]::GetExtension($fileName)
            $n = 1
            do { $candidate = Join-Path $ShareFolder ("{0}_{1}{2}" -f $base,$n,$ext); $n++ } while (Test-Path -LiteralPath $candidate)
            $target = $candidate
        }
        (New-Object System.IO.FileStream($target,[System.IO.FileMode]::CreateNew,[System.IO.FileAccess]::Write,[System.IO.FileShare]::None)).Close()
    } catch {
        return @{ ok=$false; status=500; msg=$_.Exception.Message }
    } finally {
        [System.Threading.Monitor]::Exit($Global:UploadLock)
    }

    # --- Adim 3: dosya icerigini ag'dan diske aktar ---
    # Durdurma sinyali: \r\n--<boundary>  (sonraki boundary veya son boundary)
    $delimBytes = $latin1.GetBytes("`r`n--" + $boundary)
    $delimLen   = $delimBytes.Length
    $chunkSize  = 262144  # 256 KB
    $chunk      = New-Object byte[] $chunkSize
    $overlap    = New-Object byte[] ($delimLen - 1)
    $overlapLen = 0

    $fs = $null
    try {
        $fs = New-Object System.IO.FileStream($target,[System.IO.FileMode]::Open,[System.IO.FileAccess]::Write,[System.IO.FileShare]::None,262144,[System.IO.FileOptions]::SequentialScan)
        $found = $false

        while (-not $found) {
            $read = $NetStream.Read($chunk, 0, $chunkSize)
            if ($read -le 0) { break }

            # overlap + yeni chunk birlestir
            $sbLen = $overlapLen + $read
            $sb    = New-Object byte[] $sbLen
            if ($overlapLen -gt 0) { [System.Array]::Copy($overlap, 0, $sb, 0, $overlapLen) }
            [System.Array]::Copy($chunk, 0, $sb, $overlapLen, $read)

            # boundary ara (ilk byte eslesmesine gore hizli atla)
            $d0  = $delimBytes[0]
            $pos = -1
            for ($i = 0; $i -le $sbLen - $delimLen; $i++) {
                if ($sb[$i] -ne $d0) { continue }
                $ok = $true
                for ($j = 1; $j -lt $delimLen; $j++) {
                    if ($sb[$i+$j] -ne $delimBytes[$j]) { $ok=$false; break }
                }
                if ($ok) { $pos = $i; break }
            }

            if ($pos -ge 0) {
                if ($pos -gt 0) { $fs.Write($sb, 0, $pos) }
                $found = $true
            } else {
                $safe = $sbLen - ($delimLen - 1)
                if ($safe -gt 0) { $fs.Write($sb, 0, $safe) }
                $overlapLen = [Math]::Min($delimLen - 1, $sbLen)
                if ($overlapLen -gt 0) { [System.Array]::Copy($sb, $sbLen - $overlapLen, $overlap, 0, $overlapLen) }
            }
        }

        $fs.Flush()
        return @{ ok=$true; status=200; msg=([System.IO.Path]::GetFileName($target)) }
    } catch {
        try { if ($fs) { $fs.Close() } } catch {}
        try { Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue } catch {}
        return @{ ok=$false; status=500; msg=$_.Exception.Message }
    } finally {
        try { if ($fs) { $fs.Close() } } catch {}
    }
}

# ------------------------------------------------------------------------------
#  DOSYA INDIRME (path traversal korumali, stream)
# ------------------------------------------------------------------------------
function Send-FileDownload {
    param($Req, [System.IO.Stream]$Stream)

    $q = [System.Web.HttpUtility]::ParseQueryString($Req.Query)
    $fileParam = $q['file']
    if ([string]::IsNullOrWhiteSpace($fileParam)) {
        Send-HtmlResponse -Stream $Stream -Html '<h1>400 - dosya parametresi yok</h1>' -Status 400
        return
    }

    $rootFull = [System.IO.Path]::GetFullPath($Global:ShareFolder).TrimEnd('\') + '\'
    $target   = [System.IO.Path]::GetFullPath((Join-Path $Global:ShareFolder $fileParam))

    if (-not $target.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        Send-HtmlResponse -Stream $Stream -Html '<h1>403 - erisim reddedildi</h1>' -Status 403
        return
    }
    if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
        Send-HtmlResponse -Stream $Stream -Html '<h1>404 - dosya bulunamadi</h1>' -Status 404
        return
    }

    $name    = [System.IO.Path]::GetFileName($target)
    $nameEnc = [System.Web.HttpUtility]::UrlEncode($name) -replace '\+', '%20'
    $fi      = Get-Item -LiteralPath $target

    # Header'lari elle yaz, sonra dosyayi stream et
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("HTTP/1.1 200 OK`r`n")
    [void]$sb.Append("Content-Type: application/octet-stream`r`n")
    [void]$sb.Append("Content-Disposition: attachment; filename*=UTF-8''$nameEnc`r`n")
    [void]$sb.Append("Content-Length: $($fi.Length)`r`n")
    [void]$sb.Append("Connection: close`r`n`r`n")
    $headBytes = [System.Text.Encoding]::GetEncoding(28591).GetBytes($sb.ToString())
    $Stream.Write($headBytes, 0, $headBytes.Length)

    $fs = [System.IO.File]::OpenRead($target)
    try {
        $buf = New-Object byte[] 81920
        while (($read = $fs.Read($buf, 0, $buf.Length)) -gt 0) {
            $Stream.Write($buf, 0, $read)
        }
        $Stream.Flush()
    } finally { $fs.Dispose() }
}

# ------------------------------------------------------------------------------
#  KONSOL BILGILENDIRME
# ------------------------------------------------------------------------------
function Get-WifiInterface {
    # SADECE kablosuz (Wi-Fi / 802.11) arayuzleri dondur. Ethernet/LAN haric.
    # Hotspot (192.168.137.*) varsa onceligi ona ver.
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

      L O C A L   F I L E   P O R T A L   v1.0
"@
    Write-Host $logo -ForegroundColor Cyan

    $url = "http://$($Wifi.IP):$($Global:Port)/"
    Write-Host ''
    Write-Host '  +--------------------------------------------------------+' -ForegroundColor DarkGray
    Write-Host ('  |  Baglanti URL : {0,-38} |' -f $url)                      -ForegroundColor Green
    Write-Host ('  |  Wi-Fi Adapter: {0,-38} |' -f $Wifi.Name)               -ForegroundColor Gray
    Write-Host ('  |  Subnet       : {0,-38} |' -f ("$($Wifi.IP)/$($Wifi.Prefix)")) -ForegroundColor Gray
    Write-Host ('  |  Oturum Suresi: {0,-38} |' -f '1 saat (TTL)')           -ForegroundColor Gray
    Write-Host ('  |  Max Upload   : {0,-38} |' -f '512 MB')                 -ForegroundColor Gray
    Write-Host ('  |  Klasor Yolu  : {0,-38} |' -f $Global:ShareFolder)      -ForegroundColor Gray
    Write-Host '  +--------------------------------------------------------+' -ForegroundColor DarkGray
    Write-Host ''

    Write-Host '  [SADECE Wi-Fi] Sunucu yalnizca Wi-Fi adapterinin IP adresine' -ForegroundColor Green
    Write-Host '  bind edildi. Ethernet/LAN uzerinden gelen istekler reddedilir.' -ForegroundColor Green
    if ($Wifi.Hotspot) {
        Write-Host '  [OK] Mobile Hotspot agi kullaniliyor (192.168.137.x).' -ForegroundColor Green
    }
    Write-Host ''
    Write-Host "  Parola: $Global:Password" -ForegroundColor Magenta
    Write-Host '  [ADMIN GEREKMEZ] TcpListener ile dinleniyor.' -ForegroundColor Green
    Write-Host '  Diger cihaz baglanamiyorsa: Windows Defender Firewall ilk' -ForegroundColor DarkGray
    Write-Host "  istekte izin sorabilir -> 'Ozel aglarda izin ver' sec." -ForegroundColor DarkGray
    Write-Host '  Durdurmak icin: Ctrl + C' -ForegroundColor DarkGray
    Write-Host ''
}

# ------------------------------------------------------------------------------
#  ISTEK YONLENDIRME
# ------------------------------------------------------------------------------
function Invoke-RequestRouter {
    param($Req, [System.IO.Stream]$Stream)

    $path   = $Req.Path
    $method = $Req.Method

    switch ($path) {

        '/' {
            if ($method -eq 'POST') {
                $bodyText = [System.Text.Encoding]::UTF8.GetString($Req.Body)
                $form = [System.Web.HttpUtility]::ParseQueryString($bodyText)
                $pw = $form['password']
                if ($pw -eq $Global:Password) {
                    $sid = New-SessionId
                    $now = Get-Date
                    $Global:Sessions[$sid] = @{ Created = $now; LastSeen = $now }
                    $cookie = New-SessionCookieHeader -Sid $sid
                    Send-RedirectResponse -Stream $Stream -Location '/dashboard' -ExtraHeaders @{ 'Set-Cookie' = $cookie }
                } else {
                    Send-HtmlResponse -Stream $Stream -Html (Get-LoginPage -Error $true) -Status 401
                }
            } else {
                if (Test-ValidSession -Req $Req) {
                    Send-RedirectResponse -Stream $Stream -Location '/dashboard'
                } else {
                    Send-HtmlResponse -Stream $Stream -Html (Get-LoginPage -Error $false)
                }
            }
        }

        '/dashboard' {
            if (Test-ValidSession -Req $Req) {
                Send-HtmlResponse -Stream $Stream -Html (Get-DashboardPage)
            } else {
                Send-RedirectResponse -Stream $Stream -Location '/'
            }
        }

        '/download' {
            if (Test-ValidSession -Req $Req) {
                Send-FileDownload -Req $Req -Stream $Stream
            } else {
                Send-RedirectResponse -Stream $Stream -Location '/'
            }
        }

        '/upload' {
            if (-not (Test-ValidSession -Req $Req)) {
                Send-JsonResponse -Stream $Stream -Json '{"ok":false,"msg":"Oturum gecersiz"}' -Status 401
            } elseif ($method -ne 'POST') {
                Send-JsonResponse -Stream $Stream -Json '{"ok":false,"msg":"Yalnizca POST"}' -Status 405
            } else {
                $r = Save-UploadedFileStream -NetStream $Stream -ContentType $Req.ContentType
                if ($r.ok) {
                    Send-JsonResponse -Stream $Stream -Json '{"ok":true}' -Status 200
                } else {
                    $msg = ($r.msg -replace '"', "'")
                    Send-JsonResponse -Stream $Stream -Json ('{"ok":false,"msg":"' + $msg + '"}') -Status $r.status
                }
            }
        }

        '/logout' {
            $sid = $Req.Cookies[$Global:CookieName]
            if ($sid -and $Global:Sessions.ContainsKey($sid)) { $Global:Sessions.Remove($sid) }
            $cookie = New-SessionCookieHeader -Sid '' -Expire $true
            Send-RedirectResponse -Stream $Stream -Location '/' -ExtraHeaders @{ 'Set-Cookie' = $cookie }
        }

        default {
            Send-HtmlResponse -Stream $Stream -Html '<h1>404 - bulunamadi</h1>' -Status 404
        }
    }
}

# ------------------------------------------------------------------------------
#  ANA DONGU (TcpListener)
# ------------------------------------------------------------------------------
# Wi-Fi adapter zorunlu: yoksa baslatma
$wifi = Get-WifiInterface
if ($null -eq $wifi) {
    Write-Host ''
    Write-Host '  [HATA] Aktif bir Wi-Fi (kablosuz) baglantisi bulunamadi.' -ForegroundColor Red
    Write-Host '  Bu portal yalnizca Wi-Fi uzerinden paylasima izin verir.' -ForegroundColor Yellow
    Write-Host '  Once Wi-Fi agina baglanin (veya Mobile Hotspot acin), tekrar deneyin.' -ForegroundColor Yellow
    Write-Host ''
    return
}

$bindAddr = [System.Net.IPAddress]::Parse($wifi.IP)
$listener = New-Object System.Net.Sockets.TcpListener($bindAddr, $Global:Port)

try {
    $listener.Start()
} catch {
    Write-Host ''
    Write-Host '  [HATA] Dinleyici baslatilamadi.' -ForegroundColor Red
    Write-Host "  Mesaj: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  Port $($Global:Port) baska bir uygulama tarafindan kullaniliyor olabilir." -ForegroundColor Yellow
    Write-Host '  Kontrol: netstat -ano | findstr :8080' -ForegroundColor Cyan
    Write-Host ''
    return
}

Show-StartupBanner -Wifi $wifi
Write-Host ("  Es zamanli isci (thread): {0}" -f $Global:MaxThreads) -ForegroundColor Green
Write-Host ''

# ------------------------------------------------------------------------------
#  RUNSPACE POOL  -  her baglanti ayri thread'de islenir, accept thread'i bloklanmaz
# ------------------------------------------------------------------------------
# Tum fonksiyonlari ve paylasilan degiskenleri worker runspace'lerine aktar (ISS)
$iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
$iss.ApartmentState = 'MTA'

$funcNames = @(
    'Get-IconForFile','Format-Size','Remove-ExpiredSessions','New-SessionId',
    'Read-HttpRequest','Read-RequestBody','Get-HttpStatusText','Send-Response',
    'Send-HtmlResponse','Send-JsonResponse','Send-RedirectResponse','New-SessionCookieHeader',
    'Test-ValidSession','Get-LoginPage','Get-DashboardPage','Save-UploadedFileStream',
    'Send-FileDownload','Invoke-RequestRouter'
)
foreach ($fn in $funcNames) {
    $def = (Get-Command $fn -CommandType Function).Definition
    $iss.Commands.Add((New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry($fn, $def)))
}

$sharedVars = @{
    Password    = $Global:Password
    Port        = $Global:Port
    ShareFolder = $Global:ShareFolder
    CookieName  = $Global:CookieName
    SessionTTL  = $Global:SessionTTL
    Sessions    = $Global:Sessions      # synchronized hashtable (paylasilan referans)
    UploadLock  = $Global:UploadLock
}
foreach ($k in $sharedVars.Keys) {
    $iss.Variables.Add((New-Object System.Management.Automation.Runspaces.SessionStateVariableEntry($k, $sharedVars[$k], '')))
}

$pool = [runspacefactory]::CreateRunspacePool(1, $Global:MaxThreads, $iss, $Host)
$pool.Open()

# Her baglanti icin calisan worker
$worker = {
    param($client, $ts)
    Add-Type -AssemblyName System.Web
    $stream = $null
    try {
        $client.NoDelay = $true
        $client.SendTimeout    = 300000
        $client.ReceiveTimeout = 60000
        $stream = $client.GetStream()
        $stream.ReadTimeout  = 60000
        $stream.WriteTimeout = 300000

        $req = Read-HttpRequest -Stream $stream
        if ($null -eq $req) { return }

        Write-Host ("[{0}] {1,-5} {2}" -f $ts, $req.Method, $req.RawTarget) -ForegroundColor DarkGray

        # Upload: body RAM'e yuklenmez, stream dogrudan diske akar (boyut limiti yok).
        # Diger istekler (login form vs): kucuk body RAM'e alinir.
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
        try { if ($stream) { Send-HtmlResponse -Stream $stream -Html '<h1>500 - sunucu hatasi</h1>' -Status 500 } } catch {}
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

        # Ikinci kat: gelen baglanti Wi-Fi subnet'inde mi? Degilse reddet (thread harcamadan).
        $remoteIp = $null
        try { $remoteIp = $client.Client.RemoteEndPoint.Address.ToString() } catch {}
        if ($remoteIp -and $remoteIp -ne $wifi.IP -and -not (Test-SameSubnet -ClientIp $remoteIp -LocalIp $wifi.IP -Prefix $wifi.Prefix)) {
            Write-Host ("[{0}] RED   Wi-Fi disi istemci reddedildi: {1}" -f $ts, $remoteIp) -ForegroundColor Yellow
            try { $client.Close() } catch {}
            continue
        }

        # Baglantiyi havuza ata (accept thread'i serbest kalir)
        $ps = [powershell]::Create()
        $ps.RunspacePool = $pool
        [void]$ps.AddScript($worker).AddArgument($client).AddArgument($ts)
        $handle = $ps.BeginInvoke()
        [void]$jobs.Add([pscustomobject]@{ PS = $ps; Handle = $handle })

        # Tamamlanan worker'lari topla (memory leak onleme)
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
    Write-Host '  Sunucu durduruldu.' -ForegroundColor Yellow
}

# ==============================================================================
# CALISTIRMA (ADMIN GEREKMEZ):
#   powershell.exe -ExecutionPolicy Bypass -File LocalFilePortal.ps1
#
# DOSYA PAYLASIMI (SADECE Wi-Fi):
#   - Sunucu YALNIZCA Wi-Fi adapterinin IP'sine bind edilir. Cihazlar ayni anda
#     Ethernet/LAN'a bagli olsa bile paylasim sadece Wi-Fi uzerinden calisir;
#     LAN'dan gelen istekler reddedilir (bind + subnet kontrolu, iki kat).
#   1. PC ve diger cihaz AYNI Wi-Fi agina bagli olsun.
#   2. Script'i calistir; konsoldaki Wi-Fi URL'sini not al (orn http://192.168.1.42:8080/).
#   3. Diger cihazin tarayicisina o URL'yi yaz, parola: hako123
#   4. Yuklenen dosyalar PC'de C:\SharedTransfer klasorune duser.
#   NOT: Aktif Wi-Fi yoksa script baslamaz (Wi-Fi zorunlu).
#
# ES ZAMANLI KULLANIM:
#   - Her baglanti ayri thread'de islenir (Runspace Pool, varsayilan 16 isci).
#     Birden fazla kisi ayni anda yukleyip indirebilir; biri buyuk dosya
#     yuklerken digerleri bloklanmaz/kopmaz. Esik: $Global:MaxThreads.
#
# BAGLANTI OLMUYORSA (admin GEREKMEZ, sadece firewall):
#   - Ilk istekte Windows "izin ver" sorabilir -> 'Ozel aglar' isaretli birak.
#   - Sormadiysa, firewall'da 8080 portuna gelen TCP'ye izin ver (Denetim
#     Masasi > Windows Defender Guvenlik Duvari > Gelismis > Gelen Kurallar).
# ==============================================================================
