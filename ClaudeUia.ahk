; Minimal UI Automation helpers for the Claude desktop app's Dictate button.
; Raw ComCall into IUIAutomation; vtable indices are from UIAutomationClient.h.

global UIA := ComObject("{ff48dba4-60ef-4201-aa87-54103eef594e}", "{30cbe57d-d9d0-452a-ab13-7ac5ac4825ee}")

; Button names the app uses for each state (English UI).
DICTATE_IDLE_NAME := "Dictate"
DICTATE_ACTIVE_NAME := "Stop dictation"

UIA_NamePropertyId := 30005
UIA_ControlTypePropertyId := 30003
UIA_ButtonControlTypeId := 50000
UIA_TogglePatternId := 10015
IID_IUIAutomationTogglePattern := "{94cf8058-9b8d-4ab9-8bfd-4cd0a33c8c70}"
UIA_LegacyIAccessiblePatternId := 10018
IID_IUIAutomationLegacyIAccessiblePattern := "{828055ad-355b-4435-86d5-3b51c14a9b1b}"
TreeScope_Descendants := 4

; Returns the Dictate button (caller must ObjRelease) or 0. With several composers
; open (split view): a button that is already recording wins, else the one in the pane
; holding keyboard focus, else the one nearest the mouse.
FindDictateButton(hwnd) {
    static condition := 0
    if !condition {
        isButton := CreateIntCondition(UIA_ControlTypePropertyId, UIA_ButtonControlTypeId)
        names := 0
        ComCall(28, UIA, "ptr", CreateNameCondition(DICTATE_IDLE_NAME)
            , "ptr", CreateNameCondition(DICTATE_ACTIVE_NAME), "ptr*", &names)   ; CreateOrCondition
        ComCall(25, UIA, "ptr", isButton, "ptr", names, "ptr*", &condition)   ; CreateAndCondition
    }
    root := 0
    ComCall(6, UIA, "ptr", hwnd, "ptr*", &root)   ; ElementFromHandle
    if !root
        return 0
    found := 0
    try ComCall(6, root, "int", TreeScope_Descendants, "ptr", condition, "ptr*", &found)   ; FindAll
    finally ObjRelease(root)
    if !found
        return 0

    try {
        count := 0
        ComCall(3, found, "int*", &count)   ; get_Length
        if count = 0
            return 0
        targetX := GetFocusCenterX(hwnd)
        best := 0, bestDistance := 0
        Loop count {
            el := 0
            ComCall(4, found, "int", A_Index - 1, "ptr*", &el)   ; GetElement
            if IsDictating(el) {
                if best
                    ObjRelease(best)
                return el
            }
            distance := Abs(GetRect(el).centerX - targetX)
            if !best || distance < bestDistance {
                if best
                    ObjRelease(best)
                best := el, bestDistance := distance
            } else {
                ObjRelease(el)
            }
        }
        return best
    } finally {
        ObjRelease(found)
    }
}

IsDictating(element) {
    name := 0
    ComCall(23, element, "ptr*", &name)   ; get_CurrentName
    try return StrGet(name, "UTF-16") = DICTATE_ACTIVE_NAME
    finally DllCall("oleaut32\SysFreeString", "ptr", name)
}

; Chromium intermittently omits the Toggle pattern, so fall back to the MSAA default action.
ClickDictate(element) {
    if pattern := GetPattern(element, UIA_TogglePatternId, IID_IUIAutomationTogglePattern)
        return ComCall(3, pattern)   ; Toggle
    if pattern := GetPattern(element, UIA_LegacyIAccessiblePatternId, IID_IUIAutomationLegacyIAccessiblePattern)
        return ComCall(4, pattern)   ; DoDefaultAction
    throw Error("Dictate button exposes no clickable pattern")
}

; GetCurrentPatternAs returns null for this app, so fetch IUnknown and QueryInterface.
GetPattern(element, patternId, iid) {
    unknown := 0
    ComCall(16, element, "int", patternId, "ptr*", &unknown)   ; GetCurrentPattern
    if !unknown
        return 0
    try return ComObjQuery(unknown, iid)
    finally ObjRelease(unknown)
}

; Horizontal center of the focused element if it is inside hwnd, else the mouse X.
GetFocusCenterX(hwnd) {
    focused := 0
    try ComCall(8, UIA, "ptr*", &focused)   ; GetFocusedElement
    if focused {
        try {
            pid := 0
            ComCall(20, focused, "int*", &pid)   ; get_CurrentProcessId
            if pid = WinGetPID(hwnd)
                return GetRect(focused).centerX
        } finally {
            ObjRelease(focused)
        }
    }
    CoordMode("Mouse", "Screen")
    MouseGetPos(&mouseX)
    return mouseX
}

GetRect(element) {
    r := Buffer(16)
    ComCall(43, element, "ptr", r)   ; get_CurrentBoundingRectangle
    left := NumGet(r, 0, "int"), right := NumGet(r, 8, "int")
    return {left: left, right: right, centerX: (left + right) // 2}
}

CreateIntCondition(propertyId, value) {
    variant := Buffer(24, 0)
    NumPut("ushort", 3, variant, 0)   ; VT_I4
    NumPut("int", value, variant, 8)
    cond := 0
    ComCall(23, UIA, "int", propertyId, "ptr", variant, "ptr*", &cond)   ; CreatePropertyCondition
    return cond
}

CreateNameCondition(name) {
    variant := Buffer(24, 0)
    bstr := DllCall("oleaut32\SysAllocString", "wstr", name, "ptr")
    NumPut("ushort", 8, variant, 0)   ; VT_BSTR
    NumPut("ptr", bstr, variant, 8)
    cond := 0
    try ComCall(23, UIA, "int", UIA_NamePropertyId, "ptr", variant, "ptr*", &cond)   ; CreatePropertyCondition
    finally DllCall("oleaut32\SysFreeString", "ptr", bstr)
    return cond
}
