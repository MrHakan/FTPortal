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
On Error Goto 0

fso.DeleteFile pidFile, True
MsgBox "Portal stopped (PID " & pid & ").", vbInformation, "Local File Portal"
