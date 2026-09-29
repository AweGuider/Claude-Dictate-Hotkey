#Requires AutoHotkey v2.0 64-bit
#SingleInstance Force
Persistent

#Include ClaudeUia.ahk

global IniPath := A_ScriptDir "\settings.ini"
global ClaudeWindow := "ahk_exe claude.exe ahk_class Chrome_WidgetWin_1"
global CurrentHotkey := ""
global TimeoutSeconds := 90
global AutoStopHwnd := 0

A_TrayMenu.Delete()
A_TrayMenu.Add("Settings...", ShowSettings)
A_TrayMenu.Add("Reload", (*) => Reload())
A_TrayMenu.Add("Exit", (*) => ExitApp())
A_TrayMenu.Default := "Settings..."

LoadSettings()
for arg in A_Args
    if arg = "/settings"
        ShowSettings()

LoadSettings() {
    global TimeoutSeconds
    TimeoutSeconds := Integer(IniRead(IniPath, "Settings", "TimeoutSeconds", 90))
    key := IniRead(IniPath, "Settings", "Hotkey", "^+Space")
    try {
        RegisterHotkey(key)
    } catch {
        MsgBox("Invalid hotkey in settings.ini: " key "`nFalling back to Ctrl+Shift+Space.", "Claude Dictate Hotkey", "Icon!")
        RegisterHotkey("^+Space")
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
        IniWrite(key, IniPath, "Settings", "Hotkey")
        IniWrite(TimeoutSeconds, IniPath, "Settings", "TimeoutSeconds")
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
