#Requires AutoHotkey v2.0 64-bit
#SingleInstance Force
Persistent

;@Ahk2Exe-SetName Claude Dictate Hotkey
;@Ahk2Exe-SetDescription Claude Dictate Hotkey
;@Ahk2Exe-SetVersion 0.2.0
;@Ahk2Exe-SetCopyright Copyright (c) 2026 AweDev. MIT License.
;@Ahk2Exe-SetMainIcon assets\icon.ico

#Include ClaudeUia.ahk

; A settings.ini next to the script/exe means portable mode; otherwise use %APPDATA%.
global IniPath := FileExist(A_ScriptDir "\settings.ini")
    ? A_ScriptDir "\settings.ini"
    : A_AppData "\ClaudeDictateHotkey\settings.ini"
global ClaudeWindow := "ahk_exe claude.exe ahk_class Chrome_WidgetWin_1"
global CurrentHotkey := ""
global TimeoutSeconds := 900
global SilenceSeconds := 10
global HoldThresholdMs := 500
; Claude won't start a new recording until ~2.1 s after the previous one stopped; a start
; clicked earlier is queued by Claude and begins when the cooldown ends.
global ClaudeCooldownMs := 2200
; Claude drops or delays a stop sent within roughly the first 0.7 s of a recording.
global MinRecordingMs := 900
; A delayed stop lands within ~2.2 s; only re-send a stop after longer than that.
global StopVerifyMs := 3500
global LastStopTick := 0
global StartClickTick := 0
global PendingStartUntil := 0
global Stopping := false
global AutoStopHwnd := 0
global Watch := {hwnd: 0}
global StartupShortcut := A_Startup "\Claude Dictate Hotkey.lnk"

if !A_IsCompiled && FileExist(A_ScriptDir "\assets\icon.ico")
    TraySetIcon(A_ScriptDir "\assets\icon.ico")
A_TrayMenu.Delete()
A_TrayMenu.Add("Settings...", ShowSettings)
A_TrayMenu.Add("Reload", (*) => Reload())
A_TrayMenu.Add("Exit", (*) => ExitApp())
A_TrayMenu.Default := "Settings..."

LoadSettings()
launchedAtLogin := false
for arg in A_Args {
    if arg = "/settings"
        ShowSettings()
    else if arg = "/startup"
        launchedAtLogin := true
}

; Tray icon is shown only while a Claude window exists; the hotkey itself is
; already scoped to the Claude window, so nothing else needs toggling.
UpdateTrayVisibility()
SetTimer(UpdateTrayVisibility, 2000)
if A_IconHidden && !launchedAtLogin
    ShowTip("Claude Dictate Hotkey is running and will appear when Claude opens")

UpdateTrayVisibility() {
    A_IconHidden := !WinExist(ClaudeWindow)
}

IsStartupEnabled() => FileExist(StartupShortcut) != ""

SetStartupEnabled(enabled) {
    if !enabled {
        if IsStartupEnabled()
            FileDelete(StartupShortcut)
        return
    }
    if A_IsCompiled
        FileCreateShortcut(A_ScriptFullPath, StartupShortcut, A_ScriptDir, "/startup", "Claude Dictate Hotkey")
    else
        FileCreateShortcut(A_AhkPath, StartupShortcut, A_ScriptDir, '"' A_ScriptFullPath '" /startup', "Claude Dictate Hotkey")
}

LoadSettings() {
    global TimeoutSeconds, SilenceSeconds
    TimeoutSeconds := Integer(IniRead(IniPath, "Settings", "TimeoutSeconds", 900))
    SilenceSeconds := Integer(IniRead(IniPath, "Settings", "SilenceSeconds", 10))
    key := IniRead(IniPath, "Settings", "Hotkey", "^Space")
    try {
        RegisterHotkey(key)
    } catch {
        MsgBox("Invalid hotkey in settings.ini: " key "`nFalling back to Ctrl+Space.", "Claude Dictate Hotkey", "Icon!")
        RegisterHotkey("^Space")
    }
}

; Throws if the key is not a valid AutoHotkey hotkey; the previous hotkey stays active then.
RegisterHotkey(key) {
    global CurrentHotkey
    HotIfWinActive(ClaudeWindow)
    try {
        Hotkey(key, OnDictateHotkey, "On")
        if CurrentHotkey != "" && CurrentHotkey != key
            Hotkey(CurrentHotkey, "Off")
    } finally {
        HotIfWinActive()
    }
    CurrentHotkey := key
    A_IconTip := "Claude Dictate Hotkey: " HotkeyText(key)
}

; Starts on press. A quick tap keeps recording until the next press (toggle); holding
; longer than HoldThresholdMs stops on release (push-to-talk).
OnDictateHotkey(thisHotkey) {
    global PendingStartUntil
    hwnd := WinExist("A")
    ; Another click while a queued start is pending would cancel it.
    if A_TickCount < PendingStartUntil && !IsRecording(hwnd)
        return
    PendingStartUntil := 0
    pressedAt := A_TickCount
    wasDictating := ToggleDictation(hwnd)
    if wasDictating != "" && !wasDictating {
        KeyWait(MainKey(thisHotkey))
        if A_TickCount - pressedAt >= HoldThresholdMs
            StopReliably(hwnd, 4000)
    }
}

; Calls fn(button) on a freshly found Dictate button. Claude rebuilds the button when its
; state changes, so a reference can go stale mid-call; retry with a new lookup.
; Returns fn's result, or "" if the button can't be found.
WithDictateButton(hwnd, fn) {
    if !WinExist("ahk_id " hwnd)
        return ""
    Loop 3 {
        button := FindDictateButton(hwnd)
        if !button
            return ""
        try {
            return fn(button)
        } catch {
            Sleep(100)
        } finally {
            ObjRelease(button)
        }
    }
    return ""
}

IsRecording(hwnd) => WithDictateButton(hwnd, IsDictating) = true

; Returns true if already recording, else clicks start and returns false.
StartIfIdle(button) {
    if IsDictating(button)
        return true
    ClickDictate(button)
    return false
}

; Returns true if it clicked stop, false if not recording.
StopIfRecording(button) {
    if !IsDictating(button)
        return false
    ClickDictate(button)
    return true
}

; Returns whether dictation was running before the toggle, or "" if no button was found.
ToggleDictation(hwnd) {
    global AutoStopHwnd, StartClickTick, PendingStartUntil
    wasDictating := WithDictateButton(hwnd, StartIfIdle)
    if wasDictating = "" {
        Sleep(300)   ; Chromium builds its accessibility tree on first request
        wasDictating := WithDictateButton(hwnd, StartIfIdle)
    }
    if wasDictating = "" {
        SoundBeep(400, 150)
        ShowTip("Dictate button not found")
        return ""
    }
    if wasDictating {
        StopReliably(hwnd, 0)
        return true
    }
    StartClickTick := A_TickCount
    if A_TickCount - LastStopTick < ClaudeCooldownMs {
        PendingStartUntil := LastStopTick + ClaudeCooldownMs + 300
        ShowTip("Starting... Claude is finishing the previous recording")
    }
    if TimeoutSeconds > 0 {
        AutoStopHwnd := hwnd
        SetTimer(AutoStop, -TimeoutSeconds * 1000)
    }
    StartSilenceWatch(hwnd)
    return false
}

; Stops dictation in a way Claude accepts: waits up to startWaitMs for a queued start to
; begin, lets the recording reach MinRecordingMs, then stops and re-sends once if ignored.
; Stopping blocks the auto-stop and silence timers from sending a second, conflicting stop.
StopReliably(hwnd, startWaitMs) {
    global PendingStartUntil, Stopping
    if Stopping
        return false
    Stopping := true
    try {
        deadline := A_TickCount + startWaitMs
        while !IsRecording(hwnd) && A_TickCount < deadline
            Sleep(50)
        PendingStartUntil := 0
        SetTimer(AutoStop, 0)
        SetTimer(SilenceTick, 0)
        if !IsRecording(hwnd)
            return false
        ; Earliest the recording can have begun: shortly after our click, or after Claude's cooldown.
        begunAt := Max(StartClickTick + 150, LastStopTick + ClaudeCooldownMs)
        if (wait := begunAt + MinRecordingMs - A_TickCount) > 0
            Sleep(wait)
        Loop 2 {
            StopDictation(hwnd)
            deadline := A_TickCount + StopVerifyMs
            while IsRecording(hwnd) && A_TickCount < deadline
                Sleep(100)
            if !IsRecording(hwnd)
                return true
        }
        return false
    } finally {
        Stopping := false
    }
}

; Clicks stop if dictation is running; returns true if it clicked.
StopDictation(hwnd) {
    global LastStopTick
    stopped := WithDictateButton(hwnd, StopIfRecording)
    if stopped = true
        LastStopTick := A_TickCount
    return stopped = true
}

AutoStop() {
    if !Stopping && IsRecording(AutoStopHwnd) && StopReliably(AutoStopHwnd, 0)
        ShowTip("Dictation auto-stopped after " TimeoutSeconds "s")
}

; Silence auto-stop: Claude writes the transcript into the composer while you speak, so
; no change to the composer text for SilenceSeconds means nothing is being said.
StartSilenceWatch(hwnd) {
    global Watch
    if SilenceSeconds <= 0
        return
    ReleaseWatchComposer()
    Watch := {hwnd: hwnd, composer: 0, text: "", changedAt: A_TickCount, startedAt: A_TickCount, seen: false}
    SetTimer(SilenceTick, 1000)
}

SilenceTick() {
    if Stopping
        return
    if !IsRecording(Watch.hwnd) {
        ; Allow time for a start queued behind Claude's cooldown before giving up.
        if Watch.seen || A_TickCount - Watch.startedAt > ClaudeCooldownMs + 3000 {
            SetTimer(SilenceTick, 0)
            ReleaseWatchComposer()
        }
        return
    }
    text := ReadWatchComposer()
    if !Watch.seen || text != Watch.text {
        Watch.seen := true, Watch.text := text, Watch.changedAt := A_TickCount
        return
    }
    if A_TickCount - Watch.changedAt >= SilenceSeconds * 1000 {
        SetTimer(SilenceTick, 0)
        if StopReliably(Watch.hwnd, 0)
            ShowTip("Dictation stopped after " SilenceSeconds "s of silence")
        ReleaseWatchComposer()
    }
}

; Returns the composer text, finding the composer on first use. On failure returns the last
; known text, so a lookup error never counts as new speech.
ReadWatchComposer() {
    try {
        if !Watch.composer {
            button := FindDictateButton(Watch.hwnd)
            if !button
                return Watch.text
            try Watch.composer := FindComposer(Watch.hwnd, button)
            finally ObjRelease(button)
            if !Watch.composer
                return Watch.text
        }
        return GetValue(Watch.composer)
    } catch {
        ReleaseWatchComposer()
        return Watch.text
    }
}

ReleaseWatchComposer() {
    if Watch.HasOwnProp("composer") && Watch.composer {
        ObjRelease(Watch.composer)
        Watch.composer := 0
    }
}

; "^+Space" -> "Space": the key KeyWait should watch for release.
MainKey(hotkeyName) => RegExReplace(hotkeyName, "^[#!^+<>*~$]+")

ShowSettings(*) {
    g := Gui("+AlwaysOnTop", "Claude Dictate Hotkey")
    g.SetFont("s10")
    g.AddText(, "Hotkey (active only while Claude is the focused window):")
    keyEdit := g.AddEdit("w200", CurrentHotkey)
    readable := g.AddText("x+10 yp+3 w220", HotkeyText(CurrentHotkey))
    keyEdit.OnEvent("Change", (*) => readable.Value := HotkeyText(keyEdit.Value))
    g.AddButton("xm w200", "Record new hotkey...").OnEvent("Click", (*) => RecordHotkey(keyEdit, readable))
    g.AddText("xm y+6 cGray", "Tap to start/stop, or hold to record and release to stop.")
    g.AddText("xm y+14", "Stop after this many seconds of silence (0 = never):")
    silenceEdit := g.AddEdit("w80 Number", SilenceSeconds)
    g.AddText("xm y+14", "Maximum dictation length in seconds (0 = unlimited):")
    timeoutEdit := g.AddEdit("w80 Number", TimeoutSeconds)
    startupCheck := g.AddCheckbox("xm y+14", "Start with Windows (stays hidden while Claude is closed)")
    startupCheck.Value := IsStartupEnabled()
    g.AddText("xm y+14 cGray", "Syntax: ^ = Ctrl, + = Shift, ! = Alt, # = Win  (e.g. ^+Space)")
    g.AddButton("xm y+14 w90 Default", "Save").OnEvent("Click", Save)
    g.AddButton("x+10 w90", "Cancel").OnEvent("Click", (*) => g.Destroy())
    g.OnEvent("Escape", (*) => g.Destroy())
    g.Show()

    Save(*) {
        global TimeoutSeconds, SilenceSeconds
        key := Trim(keyEdit.Value)
        try {
            RegisterHotkey(key)
        } catch {
            MsgBox("'" key "' is not a valid hotkey.", "Claude Dictate Hotkey", "Icon! Owner" g.Hwnd)
            return
        }
        TimeoutSeconds := Integer(timeoutEdit.Value || 0)
        SilenceSeconds := Integer(silenceEdit.Value || 0)
        SplitPath(IniPath, , &iniDir)
        DirCreate(iniDir)
        IniWrite(key, IniPath, "Settings", "Hotkey")
        IniWrite(SilenceSeconds, IniPath, "Settings", "SilenceSeconds")
        IniWrite(TimeoutSeconds, IniPath, "Settings", "TimeoutSeconds")
        SetStartupEnabled(startupCheck.Value)
        g.Destroy()
        ShowTip("Saved: " HotkeyText(key) ", silence stop " (SilenceSeconds ? SilenceSeconds "s" : "off")
            ", max " (TimeoutSeconds ? TimeoutSeconds "s" : "unlimited"))
    }
}

RecordHotkey(keyEdit, readable) {
    readable.Value := "Press a key combination... (Esc cancels)"
    ih := InputHook("T10")
    ih.KeyOpt("{All}", "ES")
    ih.KeyOpt("{LCtrl}{RCtrl}{LShift}{RShift}{LAlt}{RAlt}{LWin}{RWin}", "-ES")
    ih.Start()
    ih.Wait()
    if ih.EndReason = "EndKey" && ih.EndKey != "Escape" {
        mods := ""
        for symbol in ["#", "^", "!", "+"]
            if InStr(ih.EndMods, symbol)
                mods .= symbol
        keyEdit.Value := mods ih.EndKey
    }
    readable.Value := HotkeyText(keyEdit.Value)
}

HotkeyText(key) {
    names := Map("^", "Ctrl+", "+", "Shift+", "!", "Alt+", "#", "Win+")
    text := ""
    while key != "" && names.Has(SubStr(key, 1, 1)) && StrLen(key) > 1 {
        text .= names[SubStr(key, 1, 1)]
        key := SubStr(key, 2)
    }
    return text key
}

ShowTip(message) {
    ToolTip(message)
    SetTimer(() => ToolTip(), -2000)
}
