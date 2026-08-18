# Tears down a Mobile Hotspot left running by LocalFilePortal.ps1 and puts the
# machine's own hotspot SSID/passphrase back.
#
# StopPortal.vbs kills the portal with taskkill /F, so the script's own finally
# block never runs: the hotspot would stay up and the borrowed SSID would stick.
# The Wi-Fi Direct path needs no cleanup - that advertisement dies with its
# process and never touches the saved settings in the first place.
#
# Safe to run at any time, and safe to run twice.

[void][System.Reflection.Assembly]::LoadWithPartialName('System.Runtime.WindowsRuntime')

$RestoreFile = Join-Path $PSScriptRoot 'ap-restore.json'

function Invoke-WinRtAction {
    param($Action)
    $m = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
        $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and -not $_.IsGenericMethod -and
        $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncAction' })[0]
    $t = $m.Invoke($null, @($Action))
    if (-not $t.Wait(30000)) { throw 'WinRT action timed out' }
}

function Invoke-WinRtOp {
    param($Op, [Type]$ResultType)
    $m = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
        $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
        $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
    $t = $m.MakeGenericMethod($ResultType).Invoke($null, @($Op))
    if (-not $t.Wait(30000)) { throw 'WinRT operation timed out' }
    return $t.Result
}

try {
    $ni = [Windows.Networking.Connectivity.NetworkInformation, Windows.Networking.Connectivity, ContentType=WindowsRuntime]
    $tm = [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager, Windows.Networking.NetworkOperators, ContentType=WindowsRuntime]
    $prof = $ni::GetInternetConnectionProfile()
    if (-not $prof) {
        foreach ($p in $ni::GetConnectionProfiles()) {
            if ($p.NetworkAdapter -and $p.GetNetworkConnectivityLevel() -ne 'None') { $prof = $p; break }
        }
    }
    if (-not $prof) { Write-Host 'No connection profile; nothing to stop.'; return }

    $mgr = $tm::CreateFromConnectionProfile($prof)
    if ("$($mgr.TetheringOperationalState)" -eq 'On') {
        $res = Invoke-WinRtOp $mgr.StopTetheringAsync() ([Windows.Networking.NetworkOperators.NetworkOperatorTetheringOperationResult])
        Write-Host ("Hotspot stopped: {0}" -f $res.Status)
    } else {
        Write-Host 'Hotspot already off.'
    }

    # Put the machine's own SSID/passphrase back, if we parked them.
    if (Test-Path -LiteralPath $RestoreFile) {
        $orig = Get-Content -LiteralPath $RestoreFile -Raw | ConvertFrom-Json
        if ($orig -and $orig.Ssid) {
            $cfg = $mgr.GetCurrentAccessPointConfiguration()
            $cfg.Ssid = $orig.Ssid
            if ($orig.Passphrase) { $cfg.Passphrase = $orig.Passphrase }
            Invoke-WinRtAction $mgr.ConfigureAccessPointAsync($cfg)
            Write-Host ("Hotspot settings restored: SSID {0}" -f $orig.Ssid)
        }
        Remove-Item -LiteralPath $RestoreFile -Force -ErrorAction SilentlyContinue
    } else {
        Write-Host 'Nothing to restore (Wi-Fi Direct path leaves settings untouched).'
    }
} catch {
    Write-Host ("Could not stop the hotspot: {0}" -f $_.Exception.Message)
}
