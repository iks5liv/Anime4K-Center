' =========================================================
'  ai_subs.vbs - AI subtitles for yummy_ui.lua
'  Runs hidden: extract 16 kHz mono WAV (mpv), then whisper-cli
'  (NVIDIA CUDA when available, otherwise automatic CPU fallback).
'  Args: media, wav, prefix, marker, log
' =========================================================
Option Explicit

Dim sh, fso, base, root, media, wav, prefix, marker, logf
Dim mpv, whisper, model, srt, rc, ok, lang
Dim cmdBase, hasNvidia

Set sh  = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

base    = fso.GetParentFolderName(WScript.ScriptFullName)
root    = fso.GetParentFolderName(fso.GetParentFolderName(base))
' Кроссплатформенная раскладка: whisper-cli.exe может лежать в
' portable_config\whisper (как в портативной сборке), в корне проекта
' (на уровень выше ~~/) или быть установленным в систему (PATH).
mpv     = FindExe(root, "mpv.com")
If mpv = "" Then mpv = FindExe(root, "mpv.exe")
If mpv = "" Then mpv = FindExe("", "mpv.com")
If mpv = "" Then mpv = FindExe("", "mpv.exe")
whisper = FindExe(base, "whisper-cli.exe")
If whisper = "" Then whisper = FindExe(root, "whisper-cli.exe")
If whisper = "" Then whisper = FindExe("", "whisper-cli.exe")
model   = base & "\ggml-base.bin"

If WScript.Arguments.Count < 5 Then WScript.Quit 2
media  = WScript.Arguments(0)
wav    = WScript.Arguments(1)
prefix = WScript.Arguments(2)
marker = WScript.Arguments(3)
logf   = WScript.Arguments(4)
srt    = prefix & ".srt"
lang   = "auto"
If WScript.Arguments.Count >= 6 Then lang = WScript.Arguments(5)

On Error Resume Next
If fso.FileExists(marker) Then fso.DeleteFile marker, True
If fso.FileExists(wav)    Then fso.DeleteFile wav, True
If fso.FileExists(srt)    Then fso.DeleteFile srt, True
On Error GoTo 0

rc = -1
ok = False
LogLine logf, "start " & Now
LogLine logf, "media: " & media

If Not fso.FileExists(mpv) Then
    LogLine logf, "ERROR: mpv.exe not found: " & mpv
ElseIf Not fso.FileExists(whisper) Then
    LogLine logf, "ERROR: whisper-cli.exe not found: " & whisper
ElseIf Not fso.FileExists(model) Then
    LogLine logf, "ERROR: model not found: " & model
Else
    ' 1) extract audio to 16 kHz mono WAV
    Dim cmd
    cmd = Quote(mpv) & " --no-config --really-quiet --no-video" & _
          " --audio-samplerate=16000 --audio-channels=mono" & _
          " --o=" & Quote(wav) & " " & Quote(media)
    rc = sh.Run(cmd, 0, True)
    LogLine logf, "extract rc=" & rc

    If rc <> 0 Or Not fso.FileExists(wav) Then
        LogLine logf, "ERROR: audio extraction failed"
        rc = -1
    Else
        ' 2) speech recognition.
        '    NVIDIA + CUDA -> GPU (as before).
        '    AMD / Intel / no NVIDIA -> CPU fallback with --no-gpu, so
        '    whisper-cli never fails on missing cublas/CUDA libraries.
        cmdBase = Quote(whisper) & " -m " & Quote(model) & " -f " & Quote(wav) & _
              " -l " & lang & " -t 8 -osrt -of " & Quote(prefix)

        hasNvidia = HasNvidiaGpu()
        If hasNvidia Then
            LogLine logf, "GPU: NVIDIA/CUDA detected"
            rc = sh.Run(cmdBase, 0, True)
            LogLine logf, "whisper rc=" & rc
        Else
            LogLine logf, "GPU: no NVIDIA/CUDA, using CPU (--no-gpu)"
            rc = sh.Run(cmdBase & " --no-gpu", 0, True)
            LogLine logf, "whisper rc=" & rc
        End If

        ok = (rc = 0) And fso.FileExists(srt)
        If Not ok And hasNvidia Then
            ' Old driver, missing CUDA DLL or unsupported card: retry on CPU.
            ' The same model gives identical subtitles, just slower.
            LogLine logf, "CUDA run failed, retrying with --no-gpu"
            On Error Resume Next
            If fso.FileExists(srt) Then fso.DeleteFile srt, True
            On Error GoTo 0
            rc = sh.Run(cmdBase & " --no-gpu", 0, True)
            LogLine logf, "whisper CPU rc=" & rc
            ok = (rc = 0) And fso.FileExists(srt)
        End If
        If Not ok Then LogLine logf, "ERROR: no srt produced"
    End If
End If

On Error Resume Next
If fso.FileExists(wav) Then fso.DeleteFile wav, True
Dim mf
Set mf = fso.CreateTextFile(marker, True)
mf.WriteLine "rc=" & rc
mf.WriteLine "ok=" & ok
mf.WriteLine "srt=" & srt
mf.Close
On Error GoTo 0

Sub LogLine(path, text)
    Dim f, old
    On Error Resume Next
    old = ""
    If fso.FileExists(path) Then
        Set f = fso.OpenTextFile(path, 1)
        old = f.ReadAll
        f.Close
    End If
    Set f = fso.OpenTextFile(path, 2, True)
    f.Write old & text & vbCrLf
    f.Close
    On Error GoTo 0
End Sub

Function HasNvidiaGpu()
    Dim wmi, col, item, nm
    HasNvidiaGpu = False
    On Error Resume Next
    Set wmi = GetObject("winmgmts:\\.\root\cimv2")
    If Err.Number = 0 Then
        Set col = wmi.ExecQuery("SELECT Name FROM Win32_VideoController")
        If Err.Number = 0 Then
            For Each item In col
                nm = LCase(CStr(item.Name))
                If InStr(nm, "nvidia") > 0 Or InStr(nm, "geforce") > 0 Then
                    HasNvidiaGpu = True
                    Exit Function
                End If
            Next
        End If
    End If
    Err.Clear
    On Error GoTo 0
End Function

Function Quote(s)
    Quote = """" & s & """"
End Function

' Ищет файл сначала в указанной папке, затем во всех каталогах PATH.
' Возвращает полный путь или "" (пустую строку).
Function FindExe(dir, name)
    Dim cand, parts, i, p
    FindExe = ""
    If dir <> "" Then
        cand = dir & "\" & name
        If fso.FileExists(cand) Then FindExe = cand : Exit Function
    End If
    parts = Split(sh.ExpandEnvironmentStrings("%PATH%"), ";")
    For i = 0 To UBound(parts)
        p = Trim(parts(i))
        If p <> "" Then
            cand = p & "\" & name
            If fso.FileExists(cand) Then FindExe = cand : Exit Function
        End If
    Next
End Function
