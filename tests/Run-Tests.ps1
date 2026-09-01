# ==============================================================================
#  Run-Tests.ps1 - tests for LocalFilePortal.ps1
#
#  The portal is one file that starts a server the moment it is dot-sourced, so
#  these tests do not load it. They parse it, lift out every function definition
#  via the AST, and evaluate only those against globals the test sets up itself.
#  That gives real coverage of the bearer registry, the client filter and the
#  HTTP routes without a radio, a phone, or a listening socket.
#
#  Run:  powershell -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1
# ==============================================================================

$ErrorActionPreference = 'Stop'
$script:Pass = 0; $script:Fail = 0; $script:Failures = @()

function It {
    param([string]$Name, [scriptblock]$Body)
    try {
        & $Body
        $script:Pass++
        Write-Host ('  PASS  {0}' -f $Name) -ForegroundColor DarkGreen
    } catch {
        $script:Fail++
        $script:Failures += ('{0} -> {1}' -f $Name, $_.Exception.Message)
        Write-Host ('  FAIL  {0}' -f $Name) -ForegroundColor Red
        Write-Host ('        {0}' -f $_.Exception.Message) -ForegroundColor DarkRed
    }
}
function Should-Be {
    param($Actual, $Expected, [string]$Because = '')
    if ("$Actual" -ne "$Expected") { throw ("expected '{0}', got '{1}' {2}" -f $Expected, $Actual, $Because) }
}
function Should-BeTrue { param($V, [string]$M = 'expected true') if (-not $V) { throw $M } }
function Should-BeFalse { param($V, [string]$M = 'expected false') if ($V) { throw $M } }

# ---------------------------------------------------------------- load ------
$portal = Join-Path (Split-Path -Parent $PSScriptRoot) 'LocalFilePortal.ps1'
if (-not (Test-Path -LiteralPath $portal)) { throw "LocalFilePortal.ps1 not found next to tests/" }

$errs = $null; $toks = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($portal, [ref]$toks, [ref]$errs)
if ($errs -and $errs.Count) { throw ("portal has {0} parse error(s); first: {1}" -f $errs.Count, $errs[0].Message) }

$fnAsts = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
foreach ($f in $fnAsts) { Invoke-Expression $f.Extent.Text }
Write-Host ("`n  Loaded {0} functions from LocalFilePortal.ps1`n" -f $fnAsts.Count) -ForegroundColor Cyan

# ---------------------------------------------------- hardware lockout ------
# Everything that reaches a radio is replaced HERE, at script scope, before any
# test runs. This is not tidiness: an earlier version mocked inside the test
# bodies instead, and a single test that forgot to called the real thing and
# raised an actual Wi-Fi Direct access point on the developer's machine, which
# then outlived the run. No test needs the real ones, so none may reach them.
$script:BearerCalls = @()          # what the chain asked for, in order
$script:BearerFail  = @()          # kinds that should refuse to come up
$script:BearerHangs = $false

function Start-Bearer {
    param([string]$Kind, [string]$Ssid = '', [string]$Pass = '')
    $script:BearerCalls += ,@{ Kind = $Kind; Ssid = $Ssid; Pass = $Pass }
    if ($script:BearerFail -contains $Kind) { throw ('mock: {0} refuses' -f $Kind) }
    Set-BearerRecord -Kind $Kind -Ssid $Ssid -Pass $Pass -IP ('192.168.{0}.1' -f (100 + $script:BearerCalls.Count)) -Prefix 24
    return $true
}
function Start-ApHotspot   { throw 'test guard: real AP call attempted' }
function Start-ApWifiDirect{ throw 'test guard: real AP call attempted' }
function Start-StationBearer { throw 'test guard: real netsh call attempted' }
function Start-LanBearer     { throw 'test guard: real adapter call attempted' }
function Start-BluetoothPan  { throw 'test guard: real adapter call attempted' }
function Get-NetCandidates   { return @() }
function Restore-ApConfig    { return $false }
function Wait-ApAddress      { return @{ IP = '192.168.137.1'; Prefix = 24 } }

function Reset-Bearer-Mocks {
    $script:BearerCalls = @(); $script:BearerFail = @()
}
function Get-TriedKinds { return @($script:BearerCalls | ForEach-Object { $_.Kind }) }

# ------------------------------------------------------------- fixtures -----
function Reset-World {
    $Global:Password    = 'hako123'
    $Global:Port        = 80
    $Global:CookieName  = 'LDSID'
    $Global:SessionTTL  = [TimeSpan]::FromDays(365)
    $Global:DeviceTTL   = [TimeSpan]::FromMinutes(5)
    $Global:SweepEvery  = [TimeSpan]::FromMinutes(2)
    $Global:ShareFolder = Join-Path $env:TEMP 'lfp-tests'
    $Global:MetaFolder  = Join-Path $Global:ShareFolder '.meta'
    $Global:SweepState  = [hashtable]::Synchronized(@{ Last = (Get-Date) })   # skips sweep
    $Global:Sessions    = [hashtable]::Synchronized(@{})
    $Global:PubIndex    = [hashtable]::Synchronized(@{})
    $Global:Transfers   = [hashtable]::Synchronized(@{})
    $Global:Signals     = [hashtable]::Synchronized(@{})
    $Global:SignalLock  = New-Object object
    $Global:SignalTTL   = [TimeSpan]::FromSeconds(60)
    $Global:P2P         = $true
    $Global:CaptivePortal = $false
    $Global:AutoLogin   = $true
    $Global:AutoLoginKey= ''

    $Global:Bearer      = [hashtable]::Synchronized(@{ Mode='none'; Ssid=''; Pass=''; Dns=$false; IP=''; Prefix=24 })
    $Global:Bearers     = [hashtable]::Synchronized(@{})
    $Global:BearerOff   = [hashtable]::Synchronized(@{})
    $Global:BearerLock  = New-Object object
    $Global:BearerCmd   = [System.Collections.Queue]::Synchronized((New-Object System.Collections.Queue))
    $Global:Notices     = [hashtable]::Synchronized(@{ Seq = 0; Items = (New-Object System.Collections.ArrayList) })
    $Global:NoticeLock  = New-Object object
    $Global:ApWatch     = [hashtable]::Synchronized(@{ Stop=$false; Restarts=0; Switching=$false })
    $Global:BearerOrder = @('wifidirect','hotspot','station','lan')
    $Global:MultiConnect= $true
    $Global:StationFallback = $true
    $Global:LanBearer   = $true
    $Global:BluetoothPan= $false
    $Global:ApPrefer    = 'wifidirect'
    $Global:SelfAp      = $true
    $Global:ApSsid      = 'FTPHAKAN'
    $Global:ApSsidRun   = $null
    $Global:ApPassRun   = $null
}

function New-Req {
    param([string]$Path = '/', [string]$Method = 'GET', [string]$ClientIp = '192.168.137.55',
          [string]$Query = '', [string]$Body = '', [hashtable]$Cookies = $null, [hashtable]$Headers = $null)
    return @{
        Method = $Method; Path = $Path; Query = $Query; RawTarget = $Path
        Headers = $(if ($Headers) { $Headers } else { @{} })
        Cookies = $(if ($Cookies) { $Cookies } else { @{} })
        Body = [System.Text.Encoding]::UTF8.GetBytes($Body)
        ContentType = 'application/x-www-form-urlencoded'
        ContentLength = $Body.Length
        ClientIp = $ClientIp
    }
}
function Invoke-Route {
    # Runs the real router over a MemoryStream and hands back the parsed response.
    param($Req)
    $ms = New-Object System.IO.MemoryStream
    Invoke-RequestRouter -Req $Req -Stream $ms
    $raw = [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
    $split = $raw.IndexOf("`r`n`r`n")
    $head = if ($split -ge 0) { $raw.Substring(0, $split) } else { $raw }
    $body = if ($split -ge 0) { $raw.Substring($split + 4) } else { '' }
    $status = 0
    $m = [regex]::Match($head, '^HTTP/1\.1 (\d+)')
    if ($m.Success) { $status = [int]$m.Groups[1].Value }
    $json = $null
    if ($body -and $body.TrimStart().StartsWith('{')) { try { $json = $body | ConvertFrom-Json } catch {} }
    return [pscustomobject]@{ Status = $status; Head = $head; Body = $body; Json = $json }
}
function New-TestSession {
    param([string]$Sid = 'sid-test', [string]$Pub = 'pub-test', [string]$Nick = 'Tester')
    $Global:Sessions[$Sid] = @{ Sid=$Sid; PubId=$Pub; Nick=$Nick; IP='192.168.137.55'; UA='test'
                                Created=(Get-Date); LastSeen=(Get-Date) }
    $Global:PubIndex[$Pub] = $Sid
    return $Sid
}

# ============================== NOTICE BUS ====================================
Write-Host '  -- notice bus --' -ForegroundColor Yellow
Reset-World

It 'notices are handed out in order and carry a rising sequence' {
    Add-Notice -Kind 'bearer' -Text 'one'
    Add-Notice -Kind 'bearer' -Text 'two'
    $all = @(Get-NoticesAfter -Since 0)
    Should-Be $all.Count 2
    Should-Be $all[0].text 'one'
    Should-Be $all[1].seq 2
}
It 'a client that has seen up to N gets only what came after N' {
    $after = @(Get-NoticesAfter -Since 1)
    Should-Be $after.Count 1
    Should-Be $after[0].text 'two'
}
It 'a fully caught-up client gets nothing' {
    Should-Be (@(Get-NoticesAfter -Since 99)).Count 0
}
It 'the backlog is capped so a sleeping device does not replay an hour of alarms' {
    Reset-World
    1..60 | ForEach-Object { Add-Notice -Kind 'x' -Text "n$_" }
    Should-Be $Global:Notices.Items.Count 40
    Should-Be $Global:Notices.Seq 60
    # The cap drops the oldest, never the newest.
    Should-Be $Global:Notices.Items[$Global:Notices.Items.Count-1].text 'n60'
}
It 'level survives the round trip so the client can colour it' {
    Reset-World
    Add-Notice -Kind 'failover' -Text 'gone' -Level 'err'
    Should-Be (@(Get-NoticesAfter -Since 0))[0].level 'err'
}

# ============================ BEARER REGISTRY =================================
Write-Host '  -- bearer registry --' -ForegroundColor Yellow
Reset-World

It 'a registered bearer shows up as active' {
    Set-BearerRecord -Kind 'wifidirect' -Ssid 'FTPHAKAN-9A' -Pass 'abc123' -IP '192.168.137.1' -Prefix 24
    $a = @(Get-ActiveBearers)
    Should-Be $a.Count 1
    Should-Be $a[0].Kind 'wifidirect'
}
It 'a bearer with no address is not active - it could not be bound' {
    Set-BearerRecord -Kind 'station' -Ssid 'Ship' -IP '' -Prefix 24
    Should-Be (@(Get-ActiveBearers)).Count 1
}
It 'promoting a bearer mirrors it into $Global:Bearer for the pre-multi code' {
    Reset-World
    Set-BearerRecord -Kind 'hotspot' -Ssid 'FTPHAKAN-1B' -Pass 'pw' -IP '192.168.137.1' -Prefix 24
    Should-BeTrue (Set-PrimaryBearer -Kind 'hotspot')
    Should-Be $Global:Bearer.Mode 'hotspot'
    Should-Be $Global:Bearer.Ssid 'FTPHAKAN-1B'
    Should-Be $Global:Bearer.Pass 'pw'
    Should-Be $Global:Bearer.IP '192.168.137.1'
}
It 'exactly one bearer is flagged primary after a switch' {
    Set-BearerRecord -Kind 'lan' -Ssid 'Ethernet' -IP '10.0.0.5' -Prefix 24
    [void](Set-PrimaryBearer -Kind 'lan')
    $pri = @($Global:Bearers.Keys | Where-Object { $Global:Bearers[$_].Primary })
    Should-Be $pri.Count 1
    Should-Be $pri[0] 'lan'
}
It 'promoting something that is not registered fails instead of half-switching' {
    Should-BeFalse (Set-PrimaryBearer -Kind 'bluetooth')
    Should-Be $Global:Bearer.Mode 'lan'
}
It 'stopping the primary clears the mirror' {
    Stop-Bearer -Kind 'lan'
    Should-Be $Global:Bearer.Mode 'none'
    Should-BeFalse ($Global:Bearers.ContainsKey('lan'))
}
It 'stopping a secondary leaves the primary alone' {
    Reset-World
    Set-BearerRecord -Kind 'wifidirect' -Ssid 'A' -IP '192.168.137.1' -Prefix 24
    Set-BearerRecord -Kind 'lan' -Ssid 'B' -IP '10.0.0.5' -Prefix 24
    [void](Set-PrimaryBearer -Kind 'wifidirect')
    Stop-Bearer -Kind 'lan'
    Should-Be $Global:Bearer.Mode 'wifidirect'
    Should-Be (@(Get-ActiveBearers)).Count 1
}
It 'labels stay human for every kind the build knows' {
    Should-Be (Get-BearerLabel -Kind 'wifidirect' -Ssid 'x') 'Wi-Fi Direct group'
    Should-Be (Get-BearerLabel -Kind 'hotspot' -Ssid 'x') 'Mobile Hotspot'
    Should-Be (Get-BearerLabel -Kind 'lan' -Ssid 'x') 'Local network'
    Should-Be (Get-BearerLabel -Kind 'bluetooth' -Ssid 'x') 'Bluetooth PAN'
    Should-Be (Get-BearerLabel -Kind 'station' -Ssid 'Ship WiFi') 'Joined "Ship WiFi"'
    Should-Be (Get-BearerLabel -Kind 'none' -Ssid '') 'None'
}

# ======================= CLIENT FILTER (SECURITY) =============================
Write-Host '  -- client filter --' -ForegroundColor Yellow
Reset-World

It 'a device on the AP subnet is admitted' {
    Set-BearerRecord -Kind 'wifidirect' -Ssid 'A' -IP '192.168.137.1' -Prefix 24
    Should-BeTrue (Test-AllowedClient -ClientIp '192.168.137.42')
}
It 'a device on an unrelated subnet is refused' {
    Should-BeFalse (Test-AllowedClient -ClientIp '10.20.30.40')
}
It 'MultiConnect admits devices from every running bearer at once' {
    Set-BearerRecord -Kind 'lan' -Ssid 'Ship' -IP '10.20.30.5' -Prefix 24
    Should-BeTrue (Test-AllowedClient -ClientIp '192.168.137.42')  # AP side
    Should-BeTrue (Test-AllowedClient -ClientIp '10.20.30.40')     # LAN side
    Should-BeFalse (Test-AllowedClient -ClientIp '172.16.0.9')     # neither
}
It 'stopping a bearer immediately shuts its subnet out' {
    Stop-Bearer -Kind 'lan'
    Should-BeFalse (Test-AllowedClient -ClientIp '10.20.30.40')
    Should-BeTrue  (Test-AllowedClient -ClientIp '192.168.137.42')
}
It 'loopback is always allowed - it is the host browser' {
    Should-BeTrue (Test-AllowedClient -ClientIp '127.0.0.1')
}
It 'an empty client address is refused rather than defaulted open' {
    Should-BeFalse (Test-AllowedClient -ClientIp '')
    Should-BeFalse (Test-AllowedClient -ClientIp $null)
}
It 'with no registry at all it falls back to the single-interface rule' {
    Reset-World
    $Global:Bearer.IP = '192.168.1.10'; $Global:Bearer.Prefix = 24
    Should-BeTrue  (Test-AllowedClient -ClientIp '192.168.1.77')
    Should-BeFalse (Test-AllowedClient -ClientIp '192.168.2.77')
}
It 'with no registry and no address, nothing is admitted' {
    Reset-World
    Should-BeFalse (Test-AllowedClient -ClientIp '192.168.1.77')
}
It 'the LAN bearer admits every local subnet the host sits on, not just the best one' {
    # Host wired to Ethernet and joined to the site Wi-Fi: devices on either
    # must reach the portal, and the host is the host from either address.
    Reset-World
    Set-BearerRecord -Kind 'lan' -Ssid 'Wi-Fi 2' -IP '192.168.115.3' -Prefix 24 `
                     -Alt @(@{ IP = '10.0.7.35'; Prefix = 8 })
    [void](Set-PrimaryBearer -Kind 'lan')
    Should-BeTrue (Test-AllowedClient -ClientIp '192.168.115.90')  # advertised subnet
    Should-BeTrue (Test-AllowedClient -ClientIp '10.4.4.4')        # the other one
    Should-BeFalse (Test-AllowedClient -ClientIp '172.20.1.1')     # still not everything
    Should-BeTrue (Test-HostRequest -Req (New-Req -ClientIp '10.0.7.35'))
    Should-BeTrue (Test-HostRequest -Req (New-Req -ClientIp '192.168.115.3'))
    Should-BeFalse (Test-HostRequest -Req (New-Req -ClientIp '10.4.4.4'))
}
It 'a bearer with no alt subnets is unaffected by the alt check' {
    Reset-World
    Set-BearerRecord -Kind 'wifidirect' -Ssid 'A' -IP '192.168.137.1' -Prefix 24
    Should-BeTrue  (Test-AllowedClient -ClientIp '192.168.137.9')
    Should-BeFalse (Test-AllowedClient -ClientIp '10.0.0.9')
}
It 'a /16 bearer admits the whole wider range, a /24 does not' {
    Reset-World
    Set-BearerRecord -Kind 'lan' -Ssid 'Wide' -IP '172.16.0.1' -Prefix 16
    Should-BeTrue (Test-AllowedClient -ClientIp '172.16.250.9')
    Stop-Bearer -Kind 'lan'
    Set-BearerRecord -Kind 'lan' -Ssid 'Narrow' -IP '172.16.0.1' -Prefix 24
    Should-BeFalse (Test-AllowedClient -ClientIp '172.16.250.9')
}

# ============================== HOST CHECK ====================================
Write-Host '  -- host check --' -ForegroundColor Yellow
Reset-World

It 'the host is recognised on loopback' {
    Should-BeTrue (Test-HostRequest -Req (New-Req -ClientIp '127.0.0.1'))
}
It 'the host is recognised on its own bearer address' {
    Set-BearerRecord -Kind 'wifidirect' -Ssid 'A' -IP '192.168.137.1' -Prefix 24
    Should-BeTrue (Test-HostRequest -Req (New-Req -ClientIp '192.168.137.1'))
}
It 'a phone on the same AP is NOT the host, even though it is allowed in' {
    Should-BeTrue  (Test-AllowedClient -ClientIp '192.168.137.42')
    Should-BeFalse (Test-HostRequest -Req (New-Req -ClientIp '192.168.137.42'))
}
It 'the host address of a stopped bearer stops counting as the host' {
    Stop-Bearer -Kind 'wifidirect'
    Should-BeFalse (Test-HostRequest -Req (New-Req -ClientIp '192.168.137.1'))
}

# ============================ BEARER LIST JSON ================================
Write-Host '  -- bearer list --' -ForegroundColor Yellow
Reset-World

It 'every known transport is listed, running or not, so it can be offered' {
    $l = @(Get-BearerListJson)
    Should-Be $l.Count 5
    Should-Be (@($l | Where-Object { $_.kind -eq 'bluetooth' })).Count 1
}
It 'a transport switched off in settings is listed as disabled' {
    $bt = @(Get-BearerListJson | Where-Object { $_.kind -eq 'bluetooth' })[0]
    Should-BeFalse $bt.enabled            # $Global:BluetoothPan is $false
    $lan = @(Get-BearerListJson | Where-Object { $_.kind -eq 'lan' })[0]
    Should-BeTrue $lan.enabled
}
It 'up and primary are reported separately - several can be up, one carries' {
    Set-BearerRecord -Kind 'wifidirect' -Ssid 'A' -Pass 'p' -IP '192.168.137.1' -Prefix 24
    Set-BearerRecord -Kind 'lan' -Ssid 'Ship' -IP '10.0.0.5' -Prefix 24
    [void](Set-PrimaryBearer -Kind 'lan')
    $l = @(Get-BearerListJson)
    $wd = @($l | Where-Object { $_.kind -eq 'wifidirect' })[0]
    $ln = @($l | Where-Object { $_.kind -eq 'lan' })[0]
    Should-BeTrue $wd.up;      Should-BeFalse $wd.primary
    Should-BeTrue $ln.up;      Should-BeTrue  $ln.primary
    Should-Be (@($l | Where-Object { $_.primary })).Count 1
}

# ============================== HTTP ROUTES ===================================
Write-Host '  -- routes --' -ForegroundColor Yellow

function Setup-Routes {
    Reset-World
    Set-BearerRecord -Kind 'wifidirect' -Ssid 'FTPHAKAN-AA' -Pass 'pw123' -IP '192.168.137.1' -Prefix 24
    Set-BearerRecord -Kind 'lan' -Ssid 'Ship' -IP '10.0.0.5' -Prefix 24
    [void](Set-PrimaryBearer -Kind 'wifidirect')
    New-TestSession | Out-Null
}
$cookie = @{ 'LDSID' = 'sid-test' }

Setup-Routes
It '/api/bearer refuses a device that is not the host' {
    $r = Invoke-Route (New-Req -Path '/api/bearer' -Method 'POST' -ClientIp '192.168.137.42' `
                                -Cookies $cookie -Body 'op=switch&kind=lan')
    Should-Be $r.Status 403
    Should-Be $Global:BearerCmd.Count 0 'nothing may reach the supervisor'
}
It '/api/bearer refuses an unauthenticated request even from the host machine' {
    $r = Invoke-Route (New-Req -Path '/api/bearer' -Method 'POST' -ClientIp '127.0.0.1' -Body 'op=switch&kind=lan')
    Should-Be $r.Status 401
    Should-Be $Global:BearerCmd.Count 0
}
It '/api/bearer accepts a host switch and queues it for the supervisor' {
    $r = Invoke-Route (New-Req -Path '/api/bearer' -Method 'POST' -ClientIp '127.0.0.1' `
                                -Cookies $cookie -Body 'op=switch&kind=lan')
    Should-Be $r.Status 200
    Should-BeTrue $r.Json.ok
    Should-Be $Global:BearerCmd.Count 1
    $cmd = $Global:BearerCmd.Dequeue()
    Should-Be $cmd.Op 'switch'
    Should-Be $cmd.Kind 'lan'
}
It '/api/bearer rejects an unknown transport name' {
    $r = Invoke-Route (New-Req -Path '/api/bearer' -Method 'POST' -ClientIp '127.0.0.1' `
                                -Cookies $cookie -Body 'op=switch&kind=carrierpigeon')
    Should-Be $r.Status 400
    Should-Be $Global:BearerCmd.Count 0
}
It '/api/bearer rejects an unknown operation' {
    $r = Invoke-Route (New-Req -Path '/api/bearer' -Method 'POST' -ClientIp '127.0.0.1' `
                                -Cookies $cookie -Body 'op=destroy&kind=lan')
    Should-Be $r.Status 400
    Should-Be $Global:BearerCmd.Count 0
}
It '/api/bearer rejects GET - a switch must not be reachable by link' {
    $r = Invoke-Route (New-Req -Path '/api/bearer' -Method 'GET' -ClientIp '127.0.0.1' -Cookies $cookie)
    Should-Be $r.Status 405
}
It '/api/bearer refuses to stop the last way in' {
    Setup-Routes
    Stop-Bearer -Kind 'lan'                      # only wifidirect left
    $r = Invoke-Route (New-Req -Path '/api/bearer' -Method 'POST' -ClientIp '127.0.0.1' `
                                -Cookies $cookie -Body 'op=stop&kind=wifidirect')
    Should-Be $r.Status 409
    Should-Be $Global:BearerCmd.Count 0 'the portal must not be able to strand itself'
}
It '/api/bearer allows stopping one of two' {
    Setup-Routes
    $r = Invoke-Route (New-Req -Path '/api/bearer' -Method 'POST' -ClientIp '127.0.0.1' `
                                -Cookies $cookie -Body 'op=stop&kind=lan')
    Should-Be $r.Status 200
    Should-Be $Global:BearerCmd.Count 1
}
It '/api/bearers reports isHost false to a phone and true to the host' {
    Setup-Routes
    $phone = Invoke-Route (New-Req -Path '/api/bearers' -ClientIp '192.168.137.42' -Cookies $cookie)
    Should-Be $phone.Status 200
    Should-BeFalse $phone.Json.isHost
    $host_ = Invoke-Route (New-Req -Path '/api/bearers' -ClientIp '127.0.0.1' -Cookies $cookie)
    Should-BeTrue $host_.Json.isHost
    Should-Be $host_.Json.bearers.Count 5
}
It '/lobby is refused to a phone - it prints the Wi-Fi passphrase' {
    Setup-Routes
    $r = Invoke-Route (New-Req -Path '/lobby' -ClientIp '192.168.137.42')
    Should-Be $r.Status 404
}
It '/lobby is served to the host' {
    $r = Invoke-Route (New-Req -Path '/lobby' -ClientIp '192.168.137.1')
    Should-Be $r.Status 200
    Should-BeTrue ($r.Body -match 'Go to the portal') 'lobby offers a way into the portal'
    Should-BeTrue ($r.Body -match 'FTPHAKAN-AA')
}
It '/api/lobby is host-only and carries live bearer state for the QR redraw' {
    Setup-Routes
    Should-Be (Invoke-Route (New-Req -Path '/api/lobby' -ClientIp '192.168.137.42')).Status 404
    $r = Invoke-Route (New-Req -Path '/api/lobby' -ClientIp '127.0.0.1')
    Should-Be $r.Status 200
    Should-Be $r.Json.mode 'wifidirect'
    Should-Be $r.Json.ssid 'FTPHAKAN-AA'
    Should-Be $r.Json.pass 'pw123'
    Should-BeTrue ($r.Json.bearers.Count -eq 5)
}

# ============================ CAPTIVE INTERCEPTION ============================
Write-Host '  -- captive interception --' -ForegroundColor Yellow

It 'no interception when our DNS never bound, however many bearers are up' {
    # The LAN and station bearers never run a resolver. Redirecting there would
    # bounce a device that reached us correctly by address.
    Setup-Routes
    $Global:CaptivePortal = $true
    $Global:Bearer.Dns = $false
    $r = Invoke-Route (New-Req -Path '/api/state' -ClientIp '192.168.137.42' -Cookies $cookie `
                                -Headers @{ 'host' = 'somewhere.else' })
    Should-Be $r.Status 200 'served normally, not redirected'
}
It 'an OS connectivity probe is redirected once our DNS is up' {
    $Global:Bearer.Dns = $true
    $r = Invoke-Route (New-Req -Path '/generate_204' -ClientIp '192.168.137.42' `
                                -Headers @{ 'host' = 'connectivitycheck.gstatic.com' })
    Should-Be $r.Status 302
    Should-BeTrue ($r.Head -match 'Location:')
}
It 'a request arriving on a SECONDARY bearer address is not treated as a probe' {
    # 10.0.0.5 is the lan bearer from Setup-Routes; without this the captive
    # check would see an unfamiliar Host and bounce a legitimate device.
    $Global:Bearer.Dns = $true
    $r = Invoke-Route (New-Req -Path '/api/state' -ClientIp '10.0.0.99' -Cookies $cookie `
                                -Headers @{ 'host' = '10.0.0.5' })
    Should-Be $r.Status 200
}
It 'a request arriving on an ALT subnet address is not treated as a probe' {
    Reset-World
    Set-BearerRecord -Kind 'lan' -Ssid 'Wi-Fi' -IP '192.168.115.3' -Prefix 24 -Alt @(@{ IP='10.0.7.35'; Prefix=8 })
    [void](Set-PrimaryBearer -Kind 'lan')
    $Global:CaptivePortal = $true; $Global:Bearer.Dns = $true
    New-TestSession | Out-Null
    $r = Invoke-Route (New-Req -Path '/api/state' -ClientIp '10.4.4.4' -Cookies $cookie `
                                -Headers @{ 'host' = '10.0.7.35' })
    Should-Be $r.Status 200
}

# ============================== STATE PAYLOAD =================================
Write-Host '  -- state payload --' -ForegroundColor Yellow

It '/api/state carries the notice backlog and the sequence to resume from' {
    Setup-Routes
    Add-Notice -Kind 'failover' -Text 'hotspot dropped' -Level 'warn'
    $r = Invoke-Route (New-Req -Path '/api/state' -ClientIp '192.168.137.42' -Cookies $cookie)
    Should-Be $r.Status 200
    Should-Be $r.Json.notices.Count 1
    Should-Be $r.Json.notices[0].text 'hotspot dropped'
    Should-Be $r.Json.noticeSeq 1
}
It '/api/state?ns=N does not repeat what the client already showed' {
    $r = Invoke-Route (New-Req -Path '/api/state' -Query 'ns=1' -ClientIp '192.168.137.42' -Cookies $cookie)
    Should-Be (@($r.Json.notices)).Count 0
    Should-Be $r.Json.noticeSeq 1
}
It '/api/state marks the host so only that screen gets the transport controls' {
    $phone = Invoke-Route (New-Req -Path '/api/state' -ClientIp '192.168.137.42' -Cookies $cookie)
    Should-BeFalse $phone.Json.isHost
    $me = Invoke-Route (New-Req -Path '/api/state' -ClientIp '127.0.0.1' -Cookies $cookie)
    Should-BeTrue $me.Json.isHost
}
It '/api/state names the carrying transport in words' {
    $r = Invoke-Route (New-Req -Path '/api/state' -ClientIp '127.0.0.1' -Cookies $cookie)
    Should-Be $r.Json.bearer 'Wi-Fi Direct group'
}
It 'a garbage ns is treated as zero rather than throwing' {
    $r = Invoke-Route (New-Req -Path '/api/state' -Query 'ns=abc' -ClientIp '127.0.0.1' -Cookies $cookie)
    Should-Be $r.Status 200
    Should-Be $r.Json.notices.Count 1
}

# ========================= AUTO-LOGIN GATING ==================================
Write-Host '  -- auto-login gating --' -ForegroundColor Yellow

It 'auto-login is offered on a network we raised ourselves' {
    Reset-World
    Set-BearerRecord -Kind 'wifidirect' -Ssid 'A' -Pass 'p' -IP '192.168.137.1' -Prefix 24
    [void](Set-PrimaryBearer -Kind 'wifidirect')
    Should-BeTrue (Test-AutoLoginAllowed)
}
It 'auto-login is refused on a borrowed network - strangers are on it' {
    Reset-World
    Set-BearerRecord -Kind 'station' -Ssid 'Ship WiFi' -IP '10.0.0.9' -Prefix 24
    [void](Set-PrimaryBearer -Kind 'station')
    Should-BeFalse (Test-AutoLoginAllowed)
}
It 'auto-login is refused on the plain LAN bearer for the same reason' {
    Reset-World
    Set-BearerRecord -Kind 'lan' -Ssid 'Ethernet' -IP '10.0.0.9' -Prefix 24
    [void](Set-PrimaryBearer -Kind 'lan')
    Should-BeFalse (Test-AutoLoginAllowed)
}

# ========================== FALLBACK CHAIN ORDER ==============================
Write-Host '  -- fallback chain --' -ForegroundColor Yellow

It 'the chain tries transports in order and the first success carries' {
    Reset-World; Reset-Bearer-Mocks
    $script:BearerFail = @('wifidirect')      # adapter refuses AP mode
    $p = Start-BearerChain
    Should-Be (Get-TriedKinds)[0] 'wifidirect' 'preference is tried first'
    Should-Be $p 'hotspot' 'the first one that came up carries'
    Should-Be $Global:Bearer.Mode 'hotspot'
}
It 'MultiConnect keeps walking, so the rest are up as spares' {
    Should-BeTrue (@(Get-ActiveBearers).Count -ge 3) 'hotspot, station and lan all stayed up'
}
It 'without MultiConnect the chain stops at the first success' {
    Reset-World; Reset-Bearer-Mocks
    $Global:MultiConnect = $false
    $p = Start-BearerChain
    Should-Be $p 'wifidirect'
    Should-Be @(Get-ActiveBearers).Count 1
    Should-Be (Get-TriedKinds).Count 1 'and nothing else was even attempted'
}
It 'a transport disabled in settings is never attempted' {
    Reset-World; Reset-Bearer-Mocks
    $Global:StationFallback = $false
    $Global:LanBearer = $false
    $script:BearerFail = @('wifidirect','hotspot','station','lan','bluetooth')
    [void](Start-BearerChain)
    Should-BeFalse ((Get-TriedKinds) -contains 'station')
    Should-BeFalse ((Get-TriedKinds) -contains 'lan')
    Should-BeTrue  ((Get-TriedKinds) -contains 'wifidirect')
}
It 'bluetooth is never attempted unless it is switched on' {
    Reset-World; Reset-Bearer-Mocks
    $Global:BearerOrder = @('wifidirect','hotspot','station','lan','bluetooth')
    $script:BearerFail = @('wifidirect','hotspot','station','lan','bluetooth')
    [void](Start-BearerChain)
    Should-BeFalse ((Get-TriedKinds) -contains 'bluetooth') 'BluetoothPan is $false by default'
    Reset-Bearer-Mocks
    $Global:BluetoothPan = $true
    [void](Start-BearerChain)
    Should-BeTrue ((Get-TriedKinds) -contains 'bluetooth')
}
It '-Prefer puts a chosen transport at the head without dropping the rest' {
    Reset-World; Reset-Bearer-Mocks
    $script:BearerFail = @('wifidirect','hotspot','station','lan','bluetooth')
    [void](Start-BearerChain -Prefer 'lan')
    Should-Be (Get-TriedKinds)[0] 'lan'
    Should-Be (@((Get-TriedKinds) | Where-Object { $_ -eq 'lan' })).Count 1 'and is not tried twice'
}
It 'the run keeps ONE SSID and passphrase, so a failover does not void the QR' {
    Reset-World; Reset-Bearer-Mocks
    [void](Start-BearerChain)
    $ssids = @($script:BearerCalls | ForEach-Object { $_.Ssid } | Select-Object -Unique)
    $pws   = @($script:BearerCalls | ForEach-Object { $_.Pass } | Select-Object -Unique)
    Should-Be $ssids.Count 1 'every transport was handed the same SSID'
    Should-Be $pws.Count 1
    Should-BeTrue ($ssids[0] -like 'FTPHAKAN-*')
}
It 'a second chain run reuses the same SSID rather than minting a new one' {
    # This is what makes failover survivable: the QR already on the phone stays
    # valid when the portal moves from hotspot to Wi-Fi Direct.
    $firstSsid = $script:BearerCalls[0].Ssid
    Reset-Bearer-Mocks
    [void](Start-BearerChain -Prefer 'hotspot')
    if ($script:BearerCalls.Count -gt 0) { Should-Be $script:BearerCalls[0].Ssid $firstSsid }
}
It 'SelfAp=$false keeps the automatic chain off the radio entirely' {
    # The periodic re-arm calls this too, so a leak here would raise an access
    # point a minute after the user asked for the opposite.
    Reset-World; Reset-Bearer-Mocks
    $Global:SelfAp = $false
    $script:BearerFail = @('wifidirect','hotspot','station','lan','bluetooth')
    [void](Start-BearerChain)
    Should-BeFalse ((Get-TriedKinds) -contains 'wifidirect')
    Should-BeFalse ((Get-TriedKinds) -contains 'hotspot')
    Should-BeTrue  ((Get-TriedKinds) -contains 'lan')
}
It 'ApPrefer=hotspot reorders the chain rather than branching around it' {
    Reset-World; Reset-Bearer-Mocks
    $Global:ApPrefer = 'hotspot'
    $script:BearerFail = @('wifidirect','hotspot','station','lan','bluetooth')
    [void](Start-BearerChain)
    Should-Be (Get-TriedKinds)[0] 'hotspot'
    Should-Be (@((Get-TriedKinds) | Where-Object { $_ -eq 'hotspot' })).Count 1
}
It 'an already-running transport is not restarted by a later chain run' {
    Reset-World; Reset-Bearer-Mocks
    [void](Start-BearerChain)
    $firstCount = (Get-TriedKinds).Count
    Reset-Bearer-Mocks
    [void](Start-BearerChain)
    Should-Be (Get-TriedKinds).Count 0 'everything was already up, so nothing was touched'
    Should-BeTrue ($firstCount -ge 1)
}
It 'a transport the host closed is NOT resurrected by the periodic re-arm' {
    # The whole point of "only the host may close it" is that nothing else
    # reopens it either.
    Reset-World; Reset-Bearer-Mocks
    [void](Start-BearerChain)
    Should-BeTrue (@(Get-ActiveBearers).Count -ge 2)
    Stop-Bearer -Kind 'lan'
    $Global:BearerOff['lan'] = $true          # what the supervisor's stop op records
    Reset-Bearer-Mocks
    [void](Start-BearerChain)                 # this is the 60s re-arm
    Should-BeFalse ((Get-TriedKinds) -contains 'lan') 'the re-arm left it closed'
    Should-BeFalse ($Global:Bearers.ContainsKey('lan'))
}
It 'the host can reopen what the host closed' {
    $Global:BearerOff.Remove('lan')           # what the supervisor's start/switch op does
    Reset-Bearer-Mocks
    [void](Start-BearerChain)
    Should-BeTrue ((Get-TriedKinds) -contains 'lan')
    Should-BeTrue ($Global:Bearers.ContainsKey('lan'))
}
It 'a closed transport is reported as closed, not as broken' {
    Reset-World
    Set-BearerRecord -Kind 'wifidirect' -Ssid 'A' -IP '192.168.137.1' -Prefix 24
    [void](Set-PrimaryBearer -Kind 'wifidirect')
    $Global:BearerOff['hotspot'] = $true
    $l = @(Get-BearerListJson)
    $hs = @($l | Where-Object { $_.kind -eq 'hotspot' })[0]
    $st = @($l | Where-Object { $_.kind -eq 'station' })[0]
    Should-BeTrue  $hs.closed
    Should-BeFalse $st.closed 'never started is not the same as closed'
}
It 'the test suite never reaches a real radio' {
    # Guard on the guard: if someone deletes a mock, this fails loudly instead
    # of quietly raising an access point on the developer machine.
    foreach ($fn in @('Start-ApHotspot','Start-ApWifiDirect','Start-StationBearer','Start-LanBearer','Start-BluetoothPan')) {
        $body = (Get-Command $fn -CommandType Function).Definition
        if ($body -notmatch 'test guard') { throw "$fn is not mocked - the suite can touch hardware" }
    }
}

# =============================== SUMMARY ======================================
Write-Host ''
Write-Host ('  {0} passed, {1} failed' -f $script:Pass, $script:Fail) -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
if ($script:Fail) {
    Write-Host ''
    foreach ($f in $script:Failures) { Write-Host ('   - {0}' -f $f) -ForegroundColor Red }
    exit 1
}
Write-Host ''
exit 0
