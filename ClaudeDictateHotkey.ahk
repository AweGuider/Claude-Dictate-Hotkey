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
global TimeoutSeconds := 90
global AutoStopHwnd := 0
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
    global TimeoutSeconds
    TimeoutSeconds := Integer(IniRead(IniPath, "Settings", "TimeoutSeconds", 90))
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

OnDictateHotkey(*) {
    global AutoStopHwnd
    hwnd := WinExist("A")
    button := FindDictateButton(hwnd)
    if !button {
        Sleep(300)   ; Chromium builds its accessibility tree on first request
        button := FindDictateButton(hwnd)
    }
    if !button {
        SoundBeep(400, 150)
        ShowTip("Dictate button not found")
        return
    }
    try {
        wasDictating := IsDictating(button)
        ClickDictate(button)
    } finally {
        ObjRelease(button)
    }
    if wasDictating {
        SetTimer(AutoStop, 0)
    } else if TimeoutSeconds > 0 {
        AutoStopHwnd := hwnd
        SetTimer(AutoStop, -TimeoutSeconds * 1000)
    }
}

AutoStop() {
    if !WinExist("ahk_id " AutoStopHwnd)
        return
    button := FindDictateButton(AutoStopHwnd)
    if !button
        return
    try {
        if !IsDictating(button)
            return
        ClickDictate(button)
    } finally {
        ObjRelease(button)
    }
    ShowTip("Dictation auto-stopped after " TimeoutSeconds "s")
}

ShowSettings(*) {
    g := Gui("+AlwaysOnTop", "Claude Dictate Hotkey")
    g.SetFont("s10")
    g.AddText(, "Hotkey (active only while Claude is the focused window):")
    keyEdit := g.AddEdit("w200", CurrentHotkey)
    readable := g.AddText("x+10 yp+3 w220", HotkeyText(CurrentHotkey))
    keyEdit.OnEvent("Change", (*) => readable.Value := HotkeyText(keyEdit.Value))
    g.AddButton("xm w200", "Record new hotkey...").OnEvent("Click", (*) => RecordHotkey(keyEdit, readable))
    g.AddText("xm y+14", "Auto-stop dictation after (seconds, 0 = never):")
    timeoutEdit := g.AddEdit("w80 Number", TimeoutSeconds)
    startupCheck := g.AddCheckbox("xm y+14", "Start with Windows (stays hidden while Claude is closed)")
    startupCheck.Value := IsStartupEnabled()
    g.AddText("xm y+14 cGray", "Syntax: ^ = Ctrl, + = Shift, ! = Alt, # = Win  (e.g. ^+Space)")
    g.AddButton("xm y+14 w90 Default", "Save").OnEvent("Click", Save)
    g.AddButton("x+10 w90", "Cancel").OnEvent("Click", (*) => g.Destroy())
    g.OnEvent("Escape", (*) => g.Destroy())
    g.Show()

    Save(*) {
        global TimeoutSeconds
        key := Trim(keyEdit.Value)
        try {
            RegisterHotkey(key)
        } catch {
            MsgBox("'" key "' is not a valid hotkey.", "Claude Dictate Hotkey", "Icon! Owner" g.Hwnd)
            return
        }
        TimeoutSeconds := Integer(timeoutEdit.Value || 0)
        SplitPath(IniPath, , &iniDir)
        DirCreate(iniDir)
        IniWrite(key, IniPath, "Settings", "Hotkey")
        IniWrite(TimeoutSeconds, IniPath, "Settings", "TimeoutSeconds")
        SetStartupEnabled(startupCheck.Value)
        g.Destroy()
        ShowTip("Saved: " HotkeyText(key) ", auto-stop " (TimeoutSeconds ? TimeoutSeconds "s" : "off"))
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
