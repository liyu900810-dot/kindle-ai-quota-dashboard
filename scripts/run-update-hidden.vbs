Option Explicit

Dim shell, fso, scriptDir, updateScript, command

Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
updateScript = fso.BuildPath(scriptDir, "update-dashboard.ps1")

command = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File """ _
    & updateScript & """"

' Window style 0 keeps PowerShell and all child console processes hidden.
' Wait for completion so Task Scheduler receives the real exit code.
WScript.Quit shell.Run(command, 0, True)
