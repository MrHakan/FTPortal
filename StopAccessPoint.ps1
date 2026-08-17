# Tears down a Mobile Hotspot left running by LocalFilePortal.ps1.
#
# StopPortal.vbs kills the portal with taskkill /F, so the script's own finally
# block never runs and the hotspot would stay up after the portal is gone. The
# Wi-Fi Direct path needs no cleanup - that advertisement dies with its process.
#
# Safe to run at any time: it does nothing if tethering is already off.

[void][System.Reflection.Assembly]::LoadWithPartialName('System.Runtime.WindowsRuntime')

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
    if ("$($mgr.TetheringOperationalState)" -ne 'On') {
        Write-Host 'Hotspot already off.'
        return
    }
    $res = Invoke-WinRtOp $mgr.StopTetheringAsync() ([Windows.Networking.NetworkOperators.NetworkOperatorTetheringOperationResult])
    Write-Host ("Hotspot stopped: {0}" -f $res.Status)
} catch {
    Write-Host ("Could not stop the hotspot: {0}" -f $_.Exception.Message)
}
