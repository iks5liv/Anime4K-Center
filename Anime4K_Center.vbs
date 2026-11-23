Option Explicit
' Anime4K Center - launcher without console window
Dim fso, sh, base, ps1, cmd
Set fso = CreateObject("Scripting.FileSystemObject")
base = fso.GetParentFolderName(WScript.ScriptFullName)
ps1 = base & "\launcher.ps1"
If Not fso.FileExists(ps1) Then
    MsgBox "launcher.ps1 not found near this file.", 16, "Anime4K Center"
    WScript.Quit 1
End If
Set sh = CreateObject("WScript.Shell")
sh.CurrentDirectory = base
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & ps1 & """"
sh.Run cmd, 0, False
