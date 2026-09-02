# ==============================================================================
#  Run-IsolationTests.ps1 - runspace session-state closure checks
#
#  The portal runs code in three separate runspaces: the main thread, the HTTP
#  worker pool, and the bearer supervisor. Each of the latter two gets an
#  explicitly built InitialSessionState listing the functions and variables it
#  is allowed to see. Nothing at parse time notices when that list is short - a
#  function calling a helper nobody added is a NullReference at request time, on
#  a phone, on a ship.
#
#  So these tests read the two lists straight out of the source and prove the
#  closure: every portal function reachable from a listed entry point is itself
#  listed, and every $Global: it touches is shared in.
#
#  Run:  powershell -ExecutionPolicy Bypass -File .\tests\Run-IsolationTests.ps1
# ==============================================================================

$ErrorActionPreference = 'Stop'
$script:Pass = 0; $script:Fail = 0; $script:Failures = @()

function It {
    param([string]$Name, [scriptblock]$Body)
    try { & $Body; $script:Pass++; Write-Host ('  PASS  {0}' -f $Name) -ForegroundColor DarkGreen }
    catch {
        $script:Fail++; $script:Failures += ('{0} -> {1}' -f $Name, $_.Exception.Message)
        Write-Host ('  FAIL  {0}' -f $Name) -ForegroundColor Red
        Write-Host ('        {0}' -f $_.Exception.Message) -ForegroundColor DarkRed
    }
}

$portal = Join-Path (Split-Path -Parent $PSScriptRoot) 'FTPortal.ps1'
$errs = $null; $toks = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($portal, [ref]$toks, [ref]$errs)
if ($errs -and $errs.Count) { throw ("portal has parse errors; first: {0}" -f $errs[0].Message) }

# --------------------------------------------------------------- helpers ----
$allFns = @{}
foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    $allFns[$f.Name] = $f
}

function Get-AssignedList {
    # Pulls the string elements out of `$name = @('a','b')` anywhere in the file.
    param([string]$VarName)
    $hit = $ast.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
        $n.Left.VariablePath.UserPath -eq $VarName
    }, $true) | Select-Object -First 1
    if (-not $hit) { throw "could not find `$$VarName in the source" }
    return @($hit.Right.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true) |
             ForEach-Object { $_.Value })
}

function Get-AssignedHashKeys {
    # Pulls the keys out of `$name = @{ a = ...; b = ... }`.
    param([string]$VarName)
    $hit = $ast.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
        $n.Left.VariablePath.UserPath -eq $VarName -and
        $n.Right.Expression -is [System.Management.Automation.Language.HashtableAst]
    }, $true) | Select-Object -First 1
    if (-not $hit) { throw "could not find hashtable `$$VarName in the source" }
    return @($hit.Right.Expression.KeyValuePairs | ForEach-Object { $_.Item1.Value })
}

function Get-CalledPortalFns {
    # Portal-defined functions invoked from inside an AST node.
    param($Node)
    $out = @{}
    foreach ($c in $Node.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        $name = $c.GetCommandName()
        if ($name -and $allFns.ContainsKey($name)) { $out[$name] = $true }
    }
    return @($out.Keys)
}

function Get-TouchedGlobals {
    param($Node)
    $out = @{}
    foreach ($v in $Node.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) {
        $p = $v.VariablePath
        if ($p.IsGlobal -or $p.UserPath -like 'Global:*') {
            $out[($p.UserPath -replace '^Global:', '')] = $true
        }
    }
    return @($out.Keys)
}

function Get-Closure {
    # Everything reachable from the given entry points, transitively.
    param([string[]]$Entry)
    $seen = @{}; $queue = New-Object System.Collections.Queue
    foreach ($e in $Entry) { if ($allFns.ContainsKey($e)) { $queue.Enqueue($e) } }
    while ($queue.Count -gt 0) {
        $n = $queue.Dequeue()
        if ($seen.ContainsKey($n)) { continue }
        $seen[$n] = $true
        foreach ($c in (Get-CalledPortalFns $allFns[$n])) { if (-not $seen.ContainsKey($c)) { $queue.Enqueue($c) } }
    }
    return @($seen.Keys)
}

# Globals that are legitimately created inside the runspace at run time rather
# than shared in, plus the ones only the main thread ever touches.
$RuntimeGlobals = @(
    'ApHotspotMgr','ApPublisher','ApSsidRun','ApPassRun','ApOriginal',
    'ApWatchPs','ApWatchRs','IcsTimeoutWas','BootDone','DnsListener','CaptiveDns'
)

Write-Host ''
Write-Host '  -- HTTP worker pool session state --' -ForegroundColor Yellow

$workerFns  = Get-AssignedList 'funcNames'
$workerVars = Get-AssignedHashKeys 'sharedVars'
$workerClosure = Get-Closure -Entry $workerFns

It 'every function an HTTP worker can reach is in its session state' {
    $missing = @($workerClosure | Where-Object { $workerFns -notcontains $_ })
    if ($missing.Count) { throw ('worker runspace is missing: {0}' -f ($missing -join ', ')) }
}
It 'every $Global: an HTTP worker touches is shared into its session state' {
    $need = @{}
    foreach ($fn in $workerClosure) { foreach ($g in (Get-TouchedGlobals $allFns[$fn])) { $need[$g] = $fn } }
    $missing = @($need.Keys | Where-Object { $workerVars -notcontains $_ -and $RuntimeGlobals -notcontains $_ })
    if ($missing.Count) {
        throw ('worker runspace never sees: {0}' -f (($missing | ForEach-Object { '{0} (used by {1})' -f $_, $need[$_] }) -join '; '))
    }
}
It 'the worker list has no dead entries naming functions that do not exist' {
    $ghosts = @($workerFns | Where-Object { -not $allFns.ContainsKey($_) })
    if ($ghosts.Count) { throw ('listed but undefined: {0}' -f ($ghosts -join ', ')) }
}

Write-Host '  -- bearer supervisor session state --' -ForegroundColor Yellow

$supFns  = Get-AssignedList 'fns'
$supVars = Get-AssignedHashKeys 'vars'
$supClosure = Get-Closure -Entry $supFns

It 'every function the supervisor can reach is in its session state' {
    $missing = @($supClosure | Where-Object { $supFns -notcontains $_ })
    if ($missing.Count) { throw ('supervisor runspace is missing: {0}' -f ($missing -join ', ')) }
}
It 'every $Global: the supervisor touches is shared into its session state' {
    $need = @{}
    foreach ($fn in $supClosure) { foreach ($g in (Get-TouchedGlobals $allFns[$fn])) { $need[$g] = $fn } }
    $missing = @($need.Keys | Where-Object { $supVars -notcontains $_ -and $RuntimeGlobals -notcontains $_ })
    if ($missing.Count) {
        throw ('supervisor never sees: {0}' -f (($missing | ForEach-Object { '{0} (used by {1})' -f $_, $need[$_] }) -join '; '))
    }
}
It 'the supervisor list has no dead entries' {
    $ghosts = @($supFns | Where-Object { -not $allFns.ContainsKey($_) })
    if ($ghosts.Count) { throw ('listed but undefined: {0}' -f ($ghosts -join ', ')) }
}
It 'the supervisor can perform every operation its command mailbox accepts' {
    # /api/bearer validates op against this set; each one must be reachable.
    foreach ($fn in @('Start-Bearer','Stop-Bearer','Start-BearerChain','Set-PrimaryBearer','Add-Notice')) {
        if ($supFns -notcontains $fn) { throw "supervisor cannot $fn" }
    }
}
It 'the supervisor owns the AP objects the HTTP workers must never touch' {
    # If a worker could reach Stop-Bearer it would find $Global:ApHotspotMgr null
    # in its own runspace and silently leave the hotspot running.
    foreach ($fn in @('Start-Bearer','Stop-Bearer','Start-ApHotspot','Start-ApWifiDirect')) {
        if ($workerFns -contains $fn) { throw "$fn must not be in the HTTP worker session state" }
    }
}

Write-Host '  -- inter-runspace contract --' -ForegroundColor Yellow

It 'the mailbox and the notice bus are shared by reference into both runspaces' {
    foreach ($v in @('BearerCmd','Bearers','Notices','NoticeLock','BearerLock','Bearer','ApWatch')) {
        if ($supVars -notcontains $v) { throw "supervisor is missing shared state: $v" }
    }
    foreach ($v in @('BearerCmd','Bearers','Notices','NoticeLock','ApWatch')) {
        if ($workerVars -notcontains $v) { throw "workers are missing shared state: $v" }
    }
}
It 'every shared collection is declared synchronized at the top of the file' {
    # Sharing a plain hashtable across runspaces corrupts it under load.
    $src = Get-Content -LiteralPath $portal -Raw
    foreach ($v in @('Bearers','Notices','Sessions','Transfers','PubIndex','Signals','ApWatch')) {
        if ($src -notmatch ('\$Global:{0}\s*=\s*\[hashtable\]::Synchronized' -f $v)) {
            throw "`$Global:$v is shared across runspaces but not synchronized"
        }
    }
    if ($src -notmatch '\$Global:BearerCmd\s*=\s*\[System\.Collections\.Queue\]::Synchronized') {
        throw '$Global:BearerCmd is not a synchronized queue'
    }
}

Write-Host ''
Write-Host ('  {0} passed, {1} failed' -f $script:Pass, $script:Fail) -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
if ($script:Fail) {
    Write-Host ''
    foreach ($f in $script:Failures) { Write-Host ('   - {0}' -f $f) -ForegroundColor Red }
    exit 1
}
Write-Host ''
exit 0
