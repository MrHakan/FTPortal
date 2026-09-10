' Launches FTPortal.ps1 hidden in the background - no console window.
' Double-click this file (or put a shortcut to it in shell:startup to autorun on login).

Set fso = CreateObject("Scripting.FileSystemObject")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
ps1Path = scriptDir & "\FTPortal.ps1"

If Not fso.FileExists(ps1Path) Then
    MsgBox "FTPortal.ps1 not found next to this launcher:" & vbCrLf & ps1Path, vbCritical, "FTPortal"
    WScript.Quit 1
End If

pidFile = scriptDir & "\portal.pid"
' Wrapper writes its own PID to portal.pid before dot-sourcing the real script,
' so StopPortal.vbs can find and kill the right process later.
wrapper = "$PID | Out-File -FilePath '" & pidFile & "' -Encoding ascii -Force; & '" & ps1Path & "'"
encoded = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command " & Chr(34) & wrapper & Chr(34)

Set shell = CreateObject("WScript.Shell")
shell.Run encoded, 0, False   ' 0 = hidden window, False = don't wait
