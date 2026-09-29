#Requires AutoHotkey v2.0 64-bit
#SingleInstance Force
Persistent

;@Ahk2Exe-SetName Claude Dictate Hotkey
;@Ahk2Exe-SetDescription Claude Dictate Hotkey
;@Ahk2Exe-SetVersion 0.3.0
;@Ahk2Exe-SetCopyright Copyright (c) 2026 AweDev. MIT License.
;@Ahk2Exe-SetMainIcon assets\icon.ico

#Include ClaudeUia.ahk

; UIA reports physical pixels; make window positions physical too, so the overlay lines up
; on scaled and mixed-DPI monitors.
DllCall("SetThreadDpiAwarenessContext", "ptr", -4, "ptr")   ; PER_MONITOR_AWARE_V2

; A settings.ini next to the script/exe means portable mode; otherwise use %APPDATA%.
global IniPath := FileExist(A_ScriptDir "\settings.ini")
    ? A_ScriptDir "\settings.ini"
    : A_AppData "\ClaudeDictateHotkey\settings.ini"
global ClaudeWindow := "ahk_exe claude.exe ahk_class Chrome_WidgetWin_1"
global CurrentHotkey := ""
global TimeoutSeconds := 900
global SilenceSeconds := 10
global ShowCountdownBar := true
global ShowCountdownText := true
global PlayWarningSound := true
; Silence countdown becomes visible after this much silence (or halfway for short limits).
global SilenceWarnAfterMs := 10000
global MaxLengthWarnMs := 60000
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

; Single tick when a countdown appears; double click with echo 10 s before the stop.
global TickSound := A_ScriptDir "\assets\tick.wav"
global FinalWarningSound := A_ScriptDir "\assets\tick_echo.wav"
global FinalWarningMs := 10000
if A_IsCompiled {
    TickSound := A_Temp "\ClaudeDictateHotkey-tick.wav"
    FinalWarningSound := A_Temp "\ClaudeDictateHotkey-tick_echo.wav"
    FileInstall("assets\tick.wav", TickSound, 1)
    FileInstall("assets\tick_echo.wav", FinalWarningSound, 1)
}
global Overlay := CreateOverlay()

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
    global TimeoutSeconds, SilenceSeconds, ShowCountdownBar, ShowCountdownText, PlayWarningSound
    TimeoutSeconds := Integer(IniRead(IniPath, "Settings", "TimeoutSeconds", 900))
    SilenceSeconds := Integer(IniRead(IniPath, "Settings", "SilenceSeconds", 10))
    ShowCountdownBar := IniRead(IniPath, "Settings", "ShowCountdownBar", 1) = 1
    ShowCountdownText := IniRead(IniPath, "Settings", "ShowCountdownText", 1) = 1
    PlayWarningSound := IniRead(IniPath, "Settings", "PlayWarningSound", 1) = 1
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
    StartMonitor(hwnd)
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
        StopMonitor()
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

; Monitors a recording started by the hotkey: silence auto-stop and the countdown overlay.
; Silence = no change to the composer text, since Claude writes the transcript there live.
; The button lookup (~100 ms) runs once a second; text reads (<1 ms) run every tick.
StartMonitor(hwnd) {
    global Watch
    StopMonitor()
    Watch := {hwnd: hwnd, composer: 0, text: "", changedAt: A_TickCount, startedAt: A_TickCount
        , seen: false, lastCheck: 0, button: 0, textX: 0, warning: "", finalWarned: false, textBg: ""
        , maxEndsAt: TimeoutSeconds > 0 ? A_TickCount + TimeoutSeconds * 1000 : 0}
    SetTimer(MonitorTick, 250)
}

StopMonitor() {
    SetTimer(MonitorTick, 0)
    HideOverlay()
    ReleaseWatchComposer()
    if Watch.HasOwnProp("warning")
        Watch.warning := ""
}

MonitorTick() {
    if Stopping
        return
    now := A_TickCount
    if now - Watch.lastCheck >= 1000 {
        Watch.lastCheck := now
        button := WithDictateButton(Watch.hwnd, (b) => IsDictating(b) ? GetRect(b) : 0)
        if !button {
            HideOverlay()
            ; Allow time for a start queued behind Claude's cooldown before giving up.
            if Watch.seen || now - Watch.startedAt > ClaudeCooldownMs + 3000
                StopMonitor()
            return
        }
        Watch.button := button
        if !Watch.seen {
            Watch.seen := true
            Watch.text := ReadWatchComposer()
            Watch.changedAt := now
            Watch.textX := FindCountdownTextX(Watch.hwnd, button)
        }
    }
    if !Watch.seen
        return
    text := ReadWatchComposer()
    if text != Watch.text
        Watch.text := text, Watch.changedAt := now

    silenceMs := SilenceSeconds * 1000
    silenceLeft := silenceMs - (now - Watch.changedAt)
    if SilenceSeconds > 0 && silenceLeft <= 0 {
        StopMonitor()
        if StopReliably(Watch.hwnd, 0)
            ShowTip("Dictation stopped after " SilenceSeconds "s of silence")
        return
    }

    ; Pick the countdown that ends first, if either is in its warning window.
    warnAfter := Min(SilenceWarnAfterMs, silenceMs // 2)
    kind := "", left := 0, span := 1
    if SilenceSeconds > 0 && now - Watch.changedAt >= warnAfter
        kind := "silence", left := silenceLeft, span := silenceMs - warnAfter
    if Watch.maxEndsAt {
        maxLeft := Watch.maxEndsAt - now
        if maxLeft <= MaxLengthWarnMs && (kind = "" || maxLeft < left)
            kind := "max", left := maxLeft, span := MaxLengthWarnMs
    }
    UpdateOverlay(kind, Max(left, 0), span)
}

; Screen x for the countdown text: just right of the button row's mode button ("Auto"),
; found once per recording. Falls back to a fixed offset from the Dictate button.
FindCountdownTextX(hwnd, dictate) {
    static isButton := CreateIntCondition(UIA_ControlTypePropertyId, UIA_ButtonControlTypeId)
    fallback := dictate.right + 120
    try {
        root := 0, found := 0, count := 0, best := 0
        ComCall(6, UIA, "ptr", hwnd, "ptr*", &root)
        try ComCall(6, root, "int", TreeScope_Descendants, "ptr", isButton, "ptr*", &found)
        finally ObjRelease(root)
        ComCall(3, found, "int*", &count)
        Loop count {
            el := 0
            ComCall(4, found, "int", A_Index - 1, "ptr*", &el)
            try {
                r := GetRect(el)
                ; Same row, right of the mic and its settings chevron; nearest one wins.
                if Abs(r.top - dictate.top) < 10 && r.left > dictate.right + 10 && (!best || r.left < best.left)
                    best := r
            }
            ObjRelease(el)
        }
        ObjRelease(found)
        return best ? best.right + 12 : fallback
    } catch {
        return fallback
    }
}

; Two borderless, click-through windows that never take focus: a thin bar and a text label.
; The label window is opaque, painted with the colour sampled from behind it, so the text
; can use normal antialiasing.
CreateOverlay() {
    opts := "+AlwaysOnTop -Caption +ToolWindow -DPIScale +E0x20 +E0x08000000"
    bar := Gui(opts)
    bar.BackColor := "EF9F27"
    text := Gui(opts)
    text.MarginX := 0, text.MarginY := 0
    text.SetFont("s7 w600 q5", "Segoe UI")
    text.SetFont("s7 w600 q5", "Segoe UI Variable Text")   ; Windows 11; keeps Segoe UI if missing
    label := text.AddText("x0 y0 w320", "Max length · 0:00 left")
    label.GetPos(, , , &labelH)
    overlay := {bar: bar, text: text, label: label, labelH: labelH, barAlpha: 235, fading: false, fadeStep: 0}
    ResetOverlayAlpha(overlay)   ; also makes both windows layered, so click-through applies
    return overlay
}

ResetOverlayAlpha(overlay) {
    DetectHiddenWindows(true)
    WinSetTransparent(overlay.barAlpha, overlay.bar)
    WinSetTransparent(255, overlay.text)
}

; Immediate hide, or a short fade-out when a countdown is cancelled by speech.
HideOverlay(fade := false) {
    if fade && !Overlay.fading && (DllCall("IsWindowVisible", "ptr", Overlay.bar.Hwnd)
        || DllCall("IsWindowVisible", "ptr", Overlay.text.Hwnd)) {
        Overlay.fading := true, Overlay.fadeStep := 0
        SetTimer(FadeOverlayStep, 40)
        return
    }
    if fade && Overlay.fading
        return
    SetTimer(FadeOverlayStep, 0)
    Overlay.fading := false
    Overlay.bar.Hide()
    Overlay.text.Hide()
    ResetOverlayAlpha(Overlay)
}

FadeOverlayStep() {
    Overlay.fadeStep += 1
    remaining := 1 - Overlay.fadeStep / 8   ; ~0.3 s at 40 ms per step
    if remaining <= 0 {
        HideOverlay()
        return
    }
    WinSetTransparent(Round(Overlay.barAlpha * remaining), Overlay.bar)
    WinSetTransparent(Round(255 * remaining), Overlay.text)
}

PlayOverlaySound(file) {
    if PlayWarningSound
        try SoundPlay(file)
}

; kind: "silence", "max", or "" for no warning. left/span in ms drive the bar's length.
UpdateOverlay(kind, left, span) {
    if kind = "" {
        if Watch.warning != ""
            HideOverlay(true)
        Watch.warning := ""
        return
    }
    if kind != Watch.warning {
        Watch.warning := kind, Watch.finalWarned := false
        if left > FinalWarningMs
            PlayOverlaySound(TickSound)
    }
    if !Watch.finalWarned && left <= FinalWarningMs {
        Watch.finalWarned := true
        PlayOverlaySound(FinalWarningSound)
    }
    if !WinActive("ahk_id " Watch.hwnd) {
        HideOverlay()
        return
    }
    if Overlay.fading
        HideOverlay()   ; speech stopped again mid-fade: restore full opacity
    color := kind = "silence" ? "EF9F27" : "E24B4A"
    b := Watch.button
    if ShowCountdownBar && Watch.composer {
        try {
            c := GetRect(Watch.composer)
            thickness := Max(2, Round(3 * DllCall("GetDpiForWindow", "ptr", Watch.hwnd, "uint") / 96))
            ; The box's padding below the text line equals half the gap to the button row;
            ; mirror it above the text line to reach the box's top edge.
            padding := (b.top - c.bottom) // 2
            y := c.top - padding - thickness // 2
            width := Max(thickness, Round((c.right - c.left) * Min(left / span, 1)))
            Overlay.bar.BackColor := color
            ; Round the ends to match Claude's rounded UI: a region clipped to a pill shape.
            DetectHiddenWindows(true)
            WinSetRegion(Format("0-0 w{} h{} r{}-{}", width, thickness, thickness, thickness), Overlay.bar)
            Overlay.bar.Show(Format("NA x{} y{} w{} h{}", c.left, y, width, thickness))
        }
    }
    if ShowCountdownText {
        if Watch.textBg = "" {
            ; Sample the empty spot the label will cover, once per recording, while it's hidden.
            CoordMode("Pixel", "Screen")
            try Watch.textBg := SubStr(PixelGetColor(Watch.textX + 4, (b.top + b.bottom) // 2), 3)
            catch
                Watch.textBg := "262624"
            Overlay.text.BackColor := Watch.textBg
        }
        secs := Ceil(left / 1000)
        label := kind = "silence"
            ? "Silent · stops in " secs "s"
            : Format("Max length · {}:{:02} left", secs // 60, Mod(secs, 60))
        Overlay.label.Value := label
        Overlay.label.SetFont("c" color)
        width := MeasureText(Overlay.label, label) + 4
        Overlay.label.Move(, , width)
        y := (b.top + b.bottom) // 2 - Overlay.labelH // 2
        Overlay.text.Show(Format("NA x{} y{} w{} h{}", Watch.textX, y, width, Overlay.labelH))
    }
}

; Pixel width of text in a control's font, so the opaque label covers only its text.
MeasureText(ctrl, str) {
    hdc := DllCall("GetDC", "ptr", ctrl.Hwnd, "ptr")
    font := SendMessage(0x31, 0, 0, ctrl)   ; WM_GETFONT
    old := DllCall("SelectObject", "ptr", hdc, "ptr", font, "ptr")
    size := Buffer(8, 0)
    DllCall("GetTextExtentPoint32W", "ptr", hdc, "wstr", str, "int", StrLen(str), "ptr", size)
    DllCall("SelectObject", "ptr", hdc, "ptr", old)
    DllCall("ReleaseDC", "ptr", ctrl.Hwnd, "ptr", hdc)
    return NumGet(size, 0, "int")
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
    g.AddText("xm y+14", "Before an automatic stop:")
    barCheck := g.AddCheckbox("xm y+6", "Show countdown bar along the top of the message box")
    barCheck.Value := ShowCountdownBar
    textCheck := g.AddCheckbox("xm", "Show countdown text next to the mic")
    textCheck.Value := ShowCountdownText
    soundCheck := g.AddCheckbox("xm", "Play warning sounds (countdown start, 10 s before the stop)")
    soundCheck.Value := PlayWarningSound
    startupCheck := g.AddCheckbox("xm y+14", "Start with Windows (stays hidden while Claude is closed)")
    startupCheck.Value := IsStartupEnabled()
    g.AddText("xm y+14 cGray", "Syntax: ^ = Ctrl, + = Shift, ! = Alt, # = Win  (e.g. ^+Space)")
    g.AddButton("xm y+14 w90 Default", "Save").OnEvent("Click", Save)
    g.AddButton("x+10 w90", "Cancel").OnEvent("Click", (*) => g.Destroy())
    g.OnEvent("Escape", (*) => g.Destroy())
    g.Show()

    Save(*) {
        global TimeoutSeconds, SilenceSeconds, ShowCountdownBar, ShowCountdownText, PlayWarningSound
        key := Trim(keyEdit.Value)
        try {
            RegisterHotkey(key)
        } catch {
            MsgBox("'" key "' is not a valid hotkey.", "Claude Dictate Hotkey", "Icon! Owner" g.Hwnd)
            return
        }
        TimeoutSeconds := Integer(timeoutEdit.Value || 0)
        SilenceSeconds := Integer(silenceEdit.Value || 0)
        ShowCountdownBar := barCheck.Value = 1
        ShowCountdownText := textCheck.Value = 1
        PlayWarningSound := soundCheck.Value = 1
        SplitPath(IniPath, , &iniDir)
        DirCreate(iniDir)
        IniWrite(key, IniPath, "Settings", "Hotkey")
        IniWrite(SilenceSeconds, IniPath, "Settings", "SilenceSeconds")
        IniWrite(TimeoutSeconds, IniPath, "Settings", "TimeoutSeconds")
        IniWrite(ShowCountdownBar ? 1 : 0, IniPath, "Settings", "ShowCountdownBar")
        IniWrite(ShowCountdownText ? 1 : 0, IniPath, "Settings", "ShowCountdownText")
        IniWrite(PlayWarningSound ? 1 : 0, IniPath, "Settings", "PlayWarningSound")
        if !ShowCountdownBar
            Overlay.bar.Hide()
        if !ShowCountdownText
            Overlay.text.Hide()
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
