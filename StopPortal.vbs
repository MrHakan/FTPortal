' Stops the hidden LocalFilePortal.ps1 process started by StartPortalHidden.vbs.

Set fso = CreateObject("Scripting.FileSystemObject")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
pidFile = scriptDir & "\portal.pid"

If Not fso.FileExists(pidFile) Then
    MsgBox "portal.pid not found - portal isn't running (or wasn't started via StartPortalHidden.vbs).", vbExclamation, "Local File Portal"
    WScript.Quit 1
End If

Set f = fso.OpenTextFile(pidFile, 1)
pid = Trim(f.ReadLine())
f.Close

Set shell = CreateObject("WScript.Shell")
On Error Resume Next
shell.Run "taskkill /F /PID " & pid, 0, True

' taskkill /F skips the script's finally block, so a Mobile Hotspot raised by the
' portal would outlive it. Tear it down explicitly. (Wi-Fi Direct needs no such
' cleanup - that advertisement dies with its process.)
apScript = scriptDir & "\StopAccessPoint.ps1"
If fso.FileExists(apScript) Then
    shell.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & apScript & """", 0, True
End If
On Error Goto 0

fso.DeleteFile pidFile, True
MsgBox "Portal stopped (PID " & pid & ") and the access point was shut down.", vbInformation, "Local File Portal"
