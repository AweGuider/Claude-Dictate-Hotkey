; Minimal UI Automation helpers for the Claude desktop app's Dictate button.
; Raw ComCall into IUIAutomation; vtable indices are from UIAutomationClient.h.

global UIA := ComObject("{ff48dba4-60ef-4201-aa87-54103eef594e}", "{30cbe57d-d9d0-452a-ab13-7ac5ac4825ee}")

; Button names the app uses for each state (English UI). With the app's "Hold to record"
; setting on, the idle button is renamed, but its accessibility toggle still starts/stops.
DICTATE_IDLE_NAME := "Dictate"
DICTATE_HOLD_IDLE_NAME := "Press and hold to record"
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
    found := FindDictateButtonArray(hwnd)
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
            ; Claude rebuilds the button on state changes; skip one that vanished mid-search.
            try {
                dictating := IsDictating(el)
                distance := Abs(GetRect(el).centerX - targetX)
            } catch {
                ObjRelease(el)
                continue
            }
            if dictating {
                if best
                    ObjRelease(best)
                return el
            }
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

; Every Dictate button in the window, one per composer (caller must ObjRelease each).
FindAllDictateButtons(hwnd) {
    buttons := []
    found := FindDictateButtonArray(hwnd)
    if !found
        return buttons
    try {
        count := 0
        ComCall(3, found, "int*", &count)   ; get_Length
        Loop count {
            el := 0
            ComCall(4, found, "int", A_Index - 1, "ptr*", &el)   ; GetElement
            buttons.Push(el)
        }
    } finally {
        ObjRelease(found)
    }
    return buttons
}

; IUIAutomationElementArray of Dictate buttons (caller must ObjRelease) or 0.
FindDictateButtonArray(hwnd) {
    static condition := 0
    if !condition {
        isButton := CreateIntCondition(UIA_ControlTypePropertyId, UIA_ButtonControlTypeId)
        idleNames := 0, names := 0
        ComCall(28, UIA, "ptr", CreateNameCondition(DICTATE_IDLE_NAME)
            , "ptr", CreateNameCondition(DICTATE_HOLD_IDLE_NAME), "ptr*", &idleNames)   ; CreateOrCondition
        ComCall(28, UIA, "ptr", idleNames
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
    return found
}

IsDictating(element) {
    name := 0
    ComCall(23, element, "ptr*", &name)   ; get_CurrentName
    try return StrGet(name, "UTF-16") = DICTATE_ACTIVE_NAME
    finally DllCall("oleaut32\SysFreeString", "ptr", name)
}

; The composer text box belonging to the given Dictate button (caller must ObjRelease) or 0:
; the Edit spanning the button horizontally, vertically closest. Claude has placed the button
; both in a row below the text (until 2026-09) and at the right end of the text row (2026-10).
FindComposer(hwnd, button) {
    static isEdit := CreateIntCondition(UIA_ControlTypePropertyId, 50004)
    b := GetRect(button)
    root := 0, found := 0, count := 0, best := 0, bestGap := 0
    ComCall(6, UIA, "ptr", hwnd, "ptr*", &root)   ; ElementFromHandle
    try ComCall(6, root, "int", TreeScope_Descendants, "ptr", isEdit, "ptr*", &found)   ; FindAll
    finally ObjRelease(root)
    try {
        ComCall(3, found, "int*", &count)
        Loop count {
            el := 0
            ComCall(4, found, "int", A_Index - 1, "ptr*", &el)
            try {
                r := GetRect(el)
                gap := Max(0, b.top - r.bottom, r.top - b.bottom)
                if r.left <= b.left + 5 && r.right >= b.right - 5 && gap < 300 && (!best || gap < bestGap) {
                    if best
                        ObjRelease(best)
                    best := el, bestGap := gap
                    continue
                }
            }
            ObjRelease(el)
        }
    } finally {
        ObjRelease(found)
    }
    return best
}

; The rounded message box around the composer and its Dictate button (caller must ObjRelease)
; or 0: the nearest ancestor that encloses both with visible padding. Control view hides it,
; so walk the raw view.
FindComposerBox(composer, button) {
    c := GetRect(composer), b := GetRect(button)
    top := Min(c.top, b.top), bottom := Max(c.bottom, b.bottom)
    walker := 0
    ComCall(16, UIA, "ptr*", &walker)   ; get_RawViewWalker
    try {
        el := composer
        ObjAddRef(el)
        Loop 8 {
            parent := 0
            ComCall(3, walker, "ptr", el, "ptr*", &parent)   ; GetParentElement
            ObjRelease(el)
            if !parent
                return 0
            r := GetRect(parent)
            if r.left <= Min(c.left, b.left) && r.right >= Max(c.right, b.right)
                && r.top <= top - 4 && r.bottom >= bottom + 4
                return parent
            el := parent
        }
        ObjRelease(el)
        return 0
    } finally {
        ObjRelease(walker)
    }
}

; Text of an Edit element (UIA ValuePattern.Value property).
GetValue(element) {
    v := Buffer(24, 0)
    ComCall(10, element, "int", 30045, "ptr", v)   ; GetCurrentPropertyValue(UIA_ValueValuePropertyId)
    try return NumGet(v, 0, "ushort") = 8 ? StrGet(NumGet(v, 8, "ptr"), "UTF-16") : ""
    finally DllCall("oleaut32\VariantClear", "ptr", v)
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
    return {left: left, top: NumGet(r, 4, "int"), right: right, bottom: NumGet(r, 12, "int"), centerX: (left + right) // 2}
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
