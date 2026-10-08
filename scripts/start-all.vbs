' Starts the whole app hidden in the background (run at boot by the
' "Chat application" scheduled task) - see start-stack.ps1.
Set objShell = CreateObject("WScript.Shell")
scriptDir = CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName)
objShell.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & scriptDir & "\start-stack.ps1""", 0, False
