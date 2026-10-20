#Requires AutoHotkey v2.0 64-bit
#SingleInstance Force
Persistent

;@Ahk2Exe-SetName Claude Dictate Hotkey
;@Ahk2Exe-SetDescription Claude Dictate Hotkey
;@Ahk2Exe-SetVersion 0.4.2
;@Ahk2Exe-SetCopyright Copyright (c) 2026 AweDev. MIT License.
;@Ahk2Exe-SetMainIcon assets\icon.ico

#Include ClaudeUia.ahk
#Include ClaudeAudio.ahk

; UIA reports physical pixels; make window positions physical too, so the overlay lines up
; on scaled and mixed-DPI monitors.
DllCall("SetThreadDpiAwarenessContext", "ptr", -4, "ptr")   ; PER_MONITOR_AWARE_V2

; A settings.ini next to the script/exe means portable mode; otherwise use %APPDATA%.
global IniPath := FileExist(A_ScriptDir "\settings.ini")
    ? A_ScriptDir "\settings.ini"
    : A_AppData "\ClaudeDictateHotkey\settings.ini"
global ClaudeWindow := "ahk_exe claude.exe ahk_class Chrome_WidgetWin_1"
global CurrentHotkey := ""
global TimeoutSeconds := 600
global SilenceSeconds := 30
; Claude's mic peak (percent of full scale) that counts as speech; 0 = judge by the text only.
global VoiceThreshold := 2
; Voice needs the level above the threshold in VoiceMinChecks of the last VoiceWindowChecks
; checks (300 of the last 500 ms), so claps and snaps don't count.
global VoicePollMs := 50
global VoiceWindowChecks := 10
global VoiceMinChecks := 6
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
global MonitorActive := false
global Watch := {hwnd: 0}
; Scan for recordings started any way (Claude's own shortcut, mouse, our hotkey).
global Scan := {hwnd: 0, buttons: [], searchedAt: 0, focusKey: "", focusCheckedAt: 0}
global ScanFocusCheckMs := 2000   ; the focus query costs ~12 ms, too much for every tick
global ScanIntervalMs := 500
; A full search costs 300–900 ms in long conversations; new panes are caught sooner by
; FocusedComposerIsNew.
global ScanResearchMs := 60000
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
SetTimer(ScanTick, ScanIntervalMs)
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
    global TimeoutSeconds, SilenceSeconds, VoiceThreshold, ShowCountdownBar, ShowCountdownText, PlayWarningSound
    TimeoutSeconds := Integer(IniRead(IniPath, "Settings", "TimeoutSeconds", 600))
    SilenceSeconds := Integer(IniRead(IniPath, "Settings", "SilenceSeconds", 30))
    VoiceThreshold := Integer(IniRead(IniPath, "Settings", "VoiceThresholdPercent", 2))
    ShowCountdownBar := IniRead(IniPath, "Settings", "ShowCountdownBar", 1) = 1
    ShowCountdownText := IniRead(IniPath, "Settings", "ShowCountdownText", 1) = 1
    PlayWarningSound := IniRead(IniPath, "Settings", "PlayWarningSound", 1) = 1
    ; Ctrl+Space for new installs. A saved empty value (unticked in Settings) means no own hotkey:
    ; Claude's dictation shortcut starts recording and this tool only watches.
    key := IniRead(IniPath, "Settings", "Hotkey", "^Space")
    try {
        RegisterHotkey(key)
    } catch {
        MsgBox("Invalid hotkey in settings.ini: " key "`nRunning without a hotkey.", "Claude Dictate Hotkey", "Icon!")
        RegisterHotkey("")
    }
}

; key "" turns the hotkey off. Throws if the key is not a valid AutoHotkey hotkey; the
; previous hotkey stays active then.
RegisterHotkey(key) {
    global CurrentHotkey
    HotIfWinActive(ClaudeWindow)
    try {
        if key != ""
            Hotkey(key, OnDictateHotkey, "On")
        if CurrentHotkey != "" && CurrentHotkey != key
            Hotkey(CurrentHotkey, "Off")
    } finally {
        HotIfWinActive()
    }
    CurrentHotkey := key
    A_IconTip := "Claude Dictate Hotkey: " (key = "" ? "no hotkey, watching dictation" : HotkeyText(key))
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
        key := MainKey(thisHotkey)
        ; The button lookup alone can exceed HoldThresholdMs (~670 ms when Claude's accessibility
        ; tree is cold); a key already released by now was a tap, not a hold.
        if !GetKeyState(key, "P")
            return
        KeyWait(key)
        if A_TickCount - pressedAt >= HoldThresholdMs
            StopReliably(hwnd, 4000)
    }
}

; Calls fn(button) on the Dictate button to act on: a held reference first (~1 ms), else a
; fresh search (300–900 ms in long chats) that also refreshes the scan's references. Claude
; sometimes rebuilds the button on a state change, so a held reference can fail mid-call;
; that retries with a fresh search. Returns fn's result, or "" if no button is found.
WithDictateButton(hwnd, fn) {
    if !WinExist("ahk_id " hwnd)
        return ""
    Loop 3 {
        button := A_Index = 1 ? KeptDictateButton(hwnd) : 0
        if !button
            button := FreshDictateButton(hwnd)
        if !button
            return ""
        try {
            return fn(button)
        } catch {
            if A_Index > 1
                Sleep(100)
        } finally {
            ObjRelease(button)
        }
    }
    return ""
}

; A held reference (caller must ObjRelease) to the button to act on, without searching: the
; monitor's button, else the scan's pick. 0 if nothing usable is held.
KeptDictateButton(hwnd) {
    if MonitorActive && Watch.hwnd = hwnd && Watch.el {
        ObjAddRef(Watch.el)
        return Watch.el
    }
    if Scan.hwnd = hwnd && Scan.buttons.Length && (el := PickDictateButton(Scan.buttons, hwnd)) {
        ObjAddRef(el)
        return el
    }
    return 0
}

; Searches the window again (caller must ObjRelease the result), refreshing the scan's
; references so the next lookups are cheap again.
FreshDictateButton(hwnd) {
    RefreshScanButtons(hwnd)
    if el := PickDictateButton(Scan.buttons, hwnd)
        ObjAddRef(el)
    return el
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
    global StartClickTick, PendingStartUntil
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
    StartMonitor(hwnd)
    return false
}

; Stops dictation in a way Claude accepts: waits up to startWaitMs for a queued start to
; begin, lets the recording reach MinRecordingMs, then stops and re-sends once if ignored.
; Stopping blocks the monitor and scan from sending a second, conflicting stop.
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

; Starts the monitor for any recording in the active Claude window, however it was started.
; Reads kept button references (~1 ms for all panes) and searches again every
; ScanResearchMs or when a reference fails. Idle while Claude isn't the active window:
; recordings can only start while it is.
ScanTick() {
    if MonitorActive || Stopping
        return
    hwnd := WinActive(ClaudeWindow)
    if !hwnd
        return
    if hwnd != Scan.hwnd || A_TickCount - Scan.searchedAt >= ScanResearchMs || FocusedComposerIsNew()
        RefreshScanButtons(hwnd)
    for button in Scan.buttons {
        try {
            if IsDictating(button) {
                StartMonitor(hwnd)
                return
            }
        } catch {
            Scan.searchedAt := 0   ; stale reference: search again next tick
            return
        }
    }
}

; True once per newly focused message box that no held button belongs to (e.g. a pane opened
; since the last search), so full searches can be rare without missing new panes.
FocusedComposerIsNew() {
    if A_TickCount - Scan.focusCheckedAt < ScanFocusCheckMs
        return false
    Scan.focusCheckedAt := A_TickCount
    focused := 0
    try ComCall(8, UIA, "ptr*", &focused)   ; GetFocusedElement
    if !focused
        return false
    try {
        controlType := 0
        ComCall(21, focused, "int*", &controlType)   ; get_CurrentControlType
        if controlType != 50004   ; Edit
            return false
        r := GetRect(focused)
    } catch {
        return false
    } finally {
        ObjRelease(focused)
    }
    key := r.left " " r.top " " r.right " " r.bottom
    if key = Scan.focusKey
        return false
    Scan.focusKey := key
    for button in Scan.buttons {
        try {
            b := GetRect(button)
            if r.left <= b.left + 5 && r.right >= b.right - 5
                && Max(0, b.top - r.bottom, r.top - b.bottom) < 300
                return false
        }
    }
    return true
}

RefreshScanButtons(hwnd) {
    for button in Scan.buttons
        ObjRelease(button)
    Scan.hwnd := hwnd
    Scan.buttons := FindAllDictateButtons(hwnd)
    Scan.searchedAt := A_TickCount
}

; Monitors a recording: silence auto-stop, maximum length, and the countdown overlay.
; Silence = no voice (VoiceTick) and no change to the composer text.
; Without Claude's mic meter, the composer text alone decides, and only once it has changed:
; since 2026-10 some accounts get no live transcript, only the full text after the stop.
; The button and meter checks run once a second; text reads (<1 ms) every tick.
StartMonitor(hwnd) {
    global Watch, MonitorActive
    StopMonitor()
    Watch := {hwnd: hwnd, composer: 0, text: "", changedAt: A_TickCount, startedAt: A_TickCount
        , seen: false, lastCheck: 0, el: 0, button: 0, box: 0, composerTriedAt: 0, textPos: ""
        , warning: "", finalWarned: false, textBg: "", maxEndsAt: 0, textChanged: false, meter: 0
        , loud: [], voiceAt: 0}
    MonitorActive := true
    SetTimer(MonitorTick, 250)
    SetTimer(VoiceTick, VoicePollMs)
}

; Voice = Claude's mic level at or above VoiceThreshold for most of the last half second.
; Measured on a Shure MV7+: claps stay loud for ~200 ms (4 of 10 checks at most), snaps ~100 ms,
; speech bursts 450 ms and longer (8–10 of 10). A level read costs ~0.2 ms.
VoiceTick() {
    if !Watch.meter
        return
    try {
        loud := MeterPeak(Watch.meter) * 100 >= VoiceThreshold
    } catch {
        Watch.meter := 0   ; MonitorTick searches again
        return
    }
    Watch.loud.Push(loud)
    if Watch.loud.Length > VoiceWindowChecks
        Watch.loud.RemoveAt(1)
    count := 0
    for isLoud in Watch.loud
        count += isLoud
    if count >= VoiceMinChecks
        Watch.voiceAt := A_TickCount
}

StopMonitor() {
    global MonitorActive
    SetTimer(MonitorTick, 0)
    SetTimer(VoiceTick, 0)
    MonitorActive := false
    Scan.searchedAt := 0   ; Claude rebuilt the buttons; refresh the scan's references
    HideOverlay()
    ReleaseWatchComposer()
    ReleaseMonitorButton()
    if Watch.HasOwnProp("meter")
        Watch.meter := 0
    if Watch.HasOwnProp("warning")
        Watch.warning := ""
}

; Rect of the recording button, or 0 if not recording. Uses a held reference; a "not recording"
; or failed read is confirmed with a fresh search, in case the reference went stale.
MonitorButtonRect() {
    Loop 2 {
        try {
            if !Watch.el
                Watch.el := A_Index = 1 ? KeptDictateButton(Watch.hwnd) : FreshDictateButton(Watch.hwnd)
            if !Watch.el
                return 0
            if IsDictating(Watch.el)
                return GetRect(Watch.el)
            if A_Index = 2
                return 0
        }
        ReleaseMonitorButton()
    }
    return 0
}

ReleaseMonitorButton() {
    if Watch.HasOwnProp("el") && Watch.el {
        ObjRelease(Watch.el)
        Watch.el := 0
    }
}

MonitorTick() {
    if Stopping
        return
    now := A_TickCount
    if now - Watch.lastCheck >= 1000 {
        Watch.lastCheck := now
        button := WinExist("ahk_id " Watch.hwnd) ? MonitorButtonRect() : 0
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
            Watch.maxEndsAt := TimeoutSeconds > 0 ? now + TimeoutSeconds * 1000 : 0
        }
        if !Watch.meter && VoiceThreshold > 0 {
            try Watch.meter := FindClaudeCaptureMeter()
            if Watch.meter
                Watch.changedAt := now   ; count silence from when there is a level to judge by
        }
    }
    if !Watch.seen
        return
    text := ReadWatchComposer()
    if text != Watch.text
        Watch.text := text, Watch.changedAt := now, Watch.textChanged := true
    if Watch.voiceAt > Watch.changedAt
        Watch.changedAt := Watch.voiceAt

    ; Never treat missing evidence as silence: no meter and no composer, or a composer that
    ; hasn't changed yet (possibly no live transcript).
    silenceOn := SilenceSeconds > 0 && (Watch.meter || Watch.composer && Watch.textChanged)
    silenceMs := SilenceSeconds * 1000
    silenceLeft := silenceMs - (now - Watch.changedAt)
    if silenceOn && silenceLeft <= 0 {
        StopMonitor()
        if StopReliably(Watch.hwnd, 0)
            ShowTip("Dictation stopped after " SilenceSeconds "s of silence")
        return
    }
    if Watch.maxEndsAt && now >= Watch.maxEndsAt {
        StopMonitor()
        if StopReliably(Watch.hwnd, 0)
            ShowTip("Dictation stopped at the maximum length (" TimeoutSeconds "s)")
        return
    }

    ; Pick the countdown that ends first, if either is in its warning window.
    warnAfter := Min(SilenceWarnAfterMs, silenceMs // 2)
    kind := "", left := 0, span := 1
    if silenceOn && now - Watch.changedAt >= warnAfter
        kind := "silence", left := silenceLeft, span := silenceMs - warnAfter
    if Watch.maxEndsAt {
        maxLeft := Watch.maxEndsAt - now
        if maxLeft <= MaxLengthWarnMs && (kind = "" || maxLeft < left)
            kind := "max", left := maxLeft, span := MaxLengthWarnMs
    }
    UpdateOverlay(kind, Max(left, 0), span)
}

; Countdown text anchor {x, y = vertical centre}, found when a countdown first appears: just
; right of the mode button ("Auto"), the leftmost button in the row under the message box.
; Searches the box's ancestors first (small subtrees, a few ms), the whole window only if
; that finds nothing. Falls back to under the box's left edge.
FindCountdownTextPos(hwnd, dictate) {
    box := ""
    if Watch.box
        try box := GetRect(Watch.box)
    if !box
        box := {left: dictate.right - 600, right: dictate.right + 20, bottom: dictate.bottom}
    try {
        if Watch.box {
            walker := 0
            ComCall(16, UIA, "ptr*", &walker)   ; get_RawViewWalker
            el := Watch.box
            ObjAddRef(el)
            Loop 4 {
                parent := 0
                ComCall(3, walker, "ptr", el, "ptr*", &parent)   ; GetParentElement
                ObjRelease(el)
                if !(el := parent)
                    break
                if best := ModeButtonUnderBox(el, box)
                    break
            }
            if el
                ObjRelease(el)
            ObjRelease(walker)
            if best
                return {x: best.right + 12, y: (best.top + best.bottom) // 2}
        }
        root := 0
        ComCall(6, UIA, "ptr", hwnd, "ptr*", &root)
        try best := ModeButtonUnderBox(root, box)
        finally ObjRelease(root)
        if best
            return {x: best.right + 12, y: (best.top + best.bottom) // 2}
    }
    return {x: box.left + 12, y: box.bottom + 18}
}

; Rect of the leftmost button in the row under the box, within scope's subtree, or 0.
ModeButtonUnderBox(scope, box) {
    static isButton := CreateIntCondition(UIA_ControlTypePropertyId, UIA_ButtonControlTypeId)
    found := 0, count := 0, best := 0
    ComCall(6, scope, "int", TreeScope_Descendants, "ptr", isButton, "ptr*", &found)   ; FindAll
    try {
        ComCall(3, found, "int*", &count)
        Loop count {
            el := 0
            ComCall(4, found, "int", A_Index - 1, "ptr*", &el)
            try {
                r := GetRect(el)
                if r.top >= box.bottom - 2 && r.top < box.bottom + 60 && r.left >= box.left - 20
                    && r.right <= box.right + 20 && (!best || r.left < best.left)
                    best := r
            }
            ObjRelease(el)
        }
    } finally {
        ObjRelease(found)
    }
    return best
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
    ; level = current opacity 0..1, animated toward target by AnimateOverlay.
    overlay := {bar: bar, text: text, label: label, labelH: labelH, barAlpha: 235, level: 0, target: 0
        , barColor: "EF9F27", barGeometry: "", textColor: "", labelText: "", labelW: 0, textGeometry: ""}
    ApplyOverlayLevel(overlay)   ; also makes both windows layered, so click-through applies
    return overlay
}

ApplyOverlayLevel(overlay) {
    DetectHiddenWindows(true)
    WinSetTransparent(Round(overlay.barAlpha * overlay.level), overlay.bar)
    WinSetTransparent(Round(255 * overlay.level), overlay.text)
}

; Fades the overlay in (target 1) or out (target 0) over ~0.3 s, continuing from the current
; opacity if a fade in the other direction is still running.
FadeOverlayTo(target) {
    if Overlay.target = target && (Overlay.level = target || target = 0 && !OverlayShown())
        return
    Overlay.target := target
    SetTimer(AnimateOverlay, 40)
}

AnimateOverlay() {
    step := 1 / 8
    Overlay.level := Overlay.target > Overlay.level
        ? Min(Overlay.level + step, 1) : Max(Overlay.level - step, 0)
    ApplyOverlayLevel(Overlay)
    if Overlay.level = Overlay.target {
        SetTimer(AnimateOverlay, 0)
        if Overlay.level = 0 {
            Overlay.bar.Hide()
            Overlay.text.Hide()
        }
    }
}

OverlayShown() => DllCall("IsWindowVisible", "ptr", Overlay.bar.Hwnd)
    || DllCall("IsWindowVisible", "ptr", Overlay.text.Hwnd)

; Immediate hide, for stops and when the monitor ends.
HideOverlay() {
    SetTimer(AnimateOverlay, 0)
    Overlay.bar.Hide()
    Overlay.text.Hide()
    Overlay.level := 0, Overlay.target := 0
    ApplyOverlayLevel(Overlay)
}

PlayOverlaySound(file) {
    if PlayWarningSound
        try SoundPlay(file)
}

; kind: "silence", "max", or "" for no warning. left/span in ms drive the bar's length.
UpdateOverlay(kind, left, span) {
    ; A stop can interrupt MonitorTick mid-run (hotkey thread); when the tick resumes it must
    ; not redraw an overlay the stop already hid, or it stays on screen with nothing to hide it.
    if !MonitorActive || Stopping {
        HideOverlay()
        return
    }
    if kind = "" {
        FadeOverlayTo(0)
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
    if !OverlayVisibleOnClaude() {
        FadeOverlayTo(0)   ; covered by another window: fade out, and back in when uncovered
        return
    }
    FadeOverlayTo(1)
    color := kind = "silence" ? "EF9F27" : "E24B4A"
    b := Watch.button
    if ShowCountdownBar && (Watch.box || Watch.composer) {
        try {
            thickness := Max(2, Round(3 * DllCall("GetDpiForWindow", "ptr", Watch.hwnd, "uint") / 96))
            if Watch.box {
                ; Along the message box's top edge, inset past its rounded corners.
                r := GetRect(Watch.box)
                x := r.left + 12, full := r.right - r.left - 24, y := r.top - thickness // 2
            } else {
                ; No box element: estimate the top edge from the text line (older layout).
                c := GetRect(Watch.composer)
                x := c.left, full := c.right - c.left
                y := c.top - Max(0, (b.top - c.bottom) // 2) - thickness // 2
            }
            width := Max(thickness, Round(full * Min(left / span, 1)))
            ; Only touch what changed since the last tick: a full redraw costs ~13 ms.
            if color != Overlay.barColor
                Overlay.bar.BackColor := Overlay.barColor := color
            geometry := x " " y " " width " " thickness
            if geometry != Overlay.barGeometry || !DllCall("IsWindowVisible", "ptr", Overlay.bar.Hwnd) {
                Overlay.barGeometry := geometry
                ; Round the ends to match Claude's rounded UI: a region clipped to a pill shape.
                DetectHiddenWindows(true)
                WinSetRegion(Format("0-0 w{} h{} r{}-{}", width, thickness, thickness, thickness), Overlay.bar)
                Overlay.bar.Show(Format("NA x{} y{} w{} h{}", x, y, width, thickness))
            }
        }
    }
    if ShowCountdownText {
        if !Watch.textPos
            Watch.textPos := FindCountdownTextPos(Watch.hwnd, b)
        if Watch.textBg = "" {
            ; Sample the empty spot the label will cover, once per recording, while it's hidden.
            CoordMode("Pixel", "Screen")
            try Watch.textBg := SubStr(PixelGetColor(Watch.textPos.x + 4, Watch.textPos.y), 3)
            catch
                Watch.textBg := "262624"
            Overlay.text.BackColor := Watch.textBg
        }
        secs := Ceil(left / 1000)
        label := kind = "silence"
            ? "Silent · stops in " secs "s"
            : Format("Max length · {}:{:02} left", secs // 60, Mod(secs, 60))
        if color != Overlay.textColor
            Overlay.label.SetFont("c" (Overlay.textColor := color))
        if label != Overlay.labelText {
            Overlay.label.Value := Overlay.labelText := label
            Overlay.labelW := MeasureText(Overlay.label, label) + 4
            Overlay.label.Move(, , Overlay.labelW)
        }
        y := Watch.textPos.y - Overlay.labelH // 2
        geometry := Watch.textPos.x " " y " " Overlay.labelW
        if geometry != Overlay.textGeometry || !DllCall("IsWindowVisible", "ptr", Overlay.text.Hwnd) {
            Overlay.textGeometry := geometry
            Overlay.text.Show(Format("NA x{} y{} w{} h{}", Watch.textPos.x, y, Overlay.labelW, Overlay.labelH))
        }
    }
}

; True if the spots the bar and text would cover show Claude, i.e. Claude is visible there even
; when another window (e.g. on another monitor) is active. Hidden when covered or minimized.
OverlayVisibleOnClaude() {
    try {
        r := Watch.box ? GetRect(Watch.box) : Watch.composer ? GetRect(Watch.composer) : Watch.button
        if !IsClaudeOnTopAt((r.left + r.right) // 2, (r.top + r.bottom) // 2)
            return false
        return !Watch.textPos || IsClaudeOnTopAt(Watch.textPos.x + 4, Watch.textPos.y)
    } catch {
        return false
    }
}

; Walks top-level windows in z-order and checks whether the first one under the point is
; Claude, skipping our overlay and windows that can't be seen or clicked (cloaked, minimized,
; click-through layered).
IsClaudeOnTopAt(x, y) {
    rect := Buffer(16)
    w := DllCall("GetTopWindow", "ptr", 0, "ptr")
    while w {
        if w != Overlay.bar.Hwnd && w != Overlay.text.Hwnd
            && DllCall("IsWindowVisible", "ptr", w) && !DllCall("IsIconic", "ptr", w) && !IsCloaked(w)
            && (WinGetExStyle(w) & 0x80020) != 0x80020 {   ; WS_EX_LAYERED | WS_EX_TRANSPARENT
            DllCall("GetWindowRect", "ptr", w, "ptr", rect)
            if x >= NumGet(rect, 0, "int") && x < NumGet(rect, 8, "int")
                && y >= NumGet(rect, 4, "int") && y < NumGet(rect, 12, "int")
                return w = Watch.hwnd
        }
        w := DllCall("GetWindow", "ptr", w, "uint", 2, "ptr")   ; GW_HWNDNEXT
    }
    return false
}

IsCloaked(hwnd) {
    cloaked := 0
    DllCall("dwmapi\DwmGetWindowAttribute", "ptr", hwnd, "uint", 14, "uint*", &cloaked, "uint", 4)   ; DWMWA_CLOAKED
    return cloaked != 0
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

; Returns the composer text, finding the composer (and its box) next to the monitored button,
; at most once a second since a search costs ~400 ms. On failure returns the last known text,
; so a lookup error never counts as new speech.
ReadWatchComposer() {
    try {
        if !Watch.composer {
            if !Watch.el || A_TickCount - Watch.composerTriedAt < 1000
                return Watch.text
            Watch.composerTriedAt := A_TickCount
            Watch.composer := FindComposerNear(Watch.el) || FindComposer(Watch.hwnd, Watch.el)
            if !Watch.composer
                return Watch.text
            Watch.box := FindComposerBox(Watch.composer, Watch.el)
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
    if Watch.HasOwnProp("box") && Watch.box {
        ObjRelease(Watch.box)
        Watch.box := 0
    }
}

; "^+Space" -> "Space": the key KeyWait should watch for release.
MainKey(hotkeyName) => RegExReplace(hotkeyName, "^[#!^+<>*~$]+")

ShowSettings(*) {
    g := Gui("+AlwaysOnTop", "Claude Dictate Hotkey")
    g.SetFont("s10")
    ownKeyCheck := g.AddCheckbox(, "Use own hotkey (tap to toggle, hold to talk)")
    ownKeyCheck.Value := CurrentHotkey != ""
    g.AddText("xm y+4 w440 cGray", "Without it, use Claude's own dictation shortcut; silence stop and the "
        . "countdown still apply. If both use the same key, this one takes over inside Claude.")
    keyEdit := g.AddEdit("xm y+8 w200", CurrentHotkey)
    readable := g.AddText("x+10 yp+3 w220", HotkeyText(CurrentHotkey))
    keyEdit.OnEvent("Change", (*) => readable.Value := HotkeyText(keyEdit.Value))
    recordButton := g.AddButton("xm w200", "Record new hotkey...")
    recordButton.OnEvent("Click", (*) => RecordHotkey(keyEdit, readable))
    syncOwnKey := (*) => (keyEdit.Enabled := recordButton.Enabled := ownKeyCheck.Value)
    ownKeyCheck.OnEvent("Click", syncOwnKey)
    syncOwnKey()
    g.AddText("xm y+14", "Stop after this many seconds of silence (0 = never):")
    silenceEdit := g.AddEdit("w80 Number", SilenceSeconds)
    g.AddText("xm y+14", "Mic level that counts as speech, in % (0 = judge by the text only):")
    voiceEdit := g.AddEdit("w80 Number", VoiceThreshold)
    g.AddText("xm y+4 w440 cGray", "Read from Claude's own recording. Raise it if background noise keeps "
        . "dictation running; lower it if quiet speech gets stopped.")
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
        global TimeoutSeconds, SilenceSeconds, VoiceThreshold, ShowCountdownBar, ShowCountdownText, PlayWarningSound
        key := ownKeyCheck.Value ? Trim(keyEdit.Value) : ""
        if ownKeyCheck.Value && key = "" {
            MsgBox("Enter or record a hotkey, or untick 'Use own hotkey'.", "Claude Dictate Hotkey", "Icon! Owner" g.Hwnd)
            return
        }
        try {
            RegisterHotkey(key)
        } catch {
            MsgBox("'" key "' is not a valid hotkey.", "Claude Dictate Hotkey", "Icon! Owner" g.Hwnd)
            return
        }
        TimeoutSeconds := Integer(timeoutEdit.Value || 0)
        SilenceSeconds := Integer(silenceEdit.Value || 0)
        VoiceThreshold := Min(Integer(voiceEdit.Value || 0), 100)
        ShowCountdownBar := barCheck.Value = 1
        ShowCountdownText := textCheck.Value = 1
        PlayWarningSound := soundCheck.Value = 1
        SplitPath(IniPath, , &iniDir)
        DirCreate(iniDir)
        IniWrite(key, IniPath, "Settings", "Hotkey")
        IniWrite(SilenceSeconds, IniPath, "Settings", "SilenceSeconds")
        IniWrite(VoiceThreshold, IniPath, "Settings", "VoiceThresholdPercent")
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
        ShowTip("Saved: " (key = "" ? "no hotkey" : HotkeyText(key)) ", silence stop " (SilenceSeconds ? SilenceSeconds "s" : "off")
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
