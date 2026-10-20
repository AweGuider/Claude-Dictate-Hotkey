; Claude's own microphone level, through Windows Core Audio sessions. Claude records through
; a capture session of its own process, so its meter reads Claude's stream alone, whichever
; device that is. Raw ComCall; vtable indices are from mmdeviceapi.h and audiopolicy.h.

; IAudioMeterInformation of Claude's active capture session, or 0 if Claude isn't recording.
FindClaudeCaptureMeter() {
    static devices := ComObject("{BCDE0395-E52F-467C-8E3D-C4579291692E}", "{A95664D2-9614-4F35-A746-DE8DB63617E6}")
    endpoints := 0, count := 0
    ComCall(3, devices, "int", 1, "uint", 1, "ptr*", &endpoints)   ; EnumAudioEndpoints(eCapture, DEVICE_STATE_ACTIVE)
    try {
        ComCall(3, endpoints, "uint*", &count)   ; GetCount
        Loop count {
            device := 0
            ComCall(4, endpoints, "uint", A_Index - 1, "ptr*", &device)   ; Item
            try {
                if meter := ClaudeSessionMeter(device)
                    return meter
            } finally {
                ObjRelease(device)
            }
        }
    } finally {
        ObjRelease(endpoints)
    }
    return 0
}

ClaudeSessionMeter(device) {
    static IID_IAudioSessionManager2 := GuidBuffer("{77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F}")
    manager := 0, sessions := 0, count := 0
    ComCall(3, device, "ptr", IID_IAudioSessionManager2, "uint", 23, "ptr", 0, "ptr*", &manager)   ; Activate(CLSCTX_ALL)
    try {
        ComCall(5, manager, "ptr*", &sessions)   ; GetSessionEnumerator
        try {
            ComCall(3, sessions, "int*", &count)   ; GetCount
            Loop count {
                control := 0
                ComCall(4, sessions, "int", A_Index - 1, "ptr*", &control)   ; GetSession
                try {
                    control2 := ComObjQuery(control, "{bfb7ff88-7239-4fc9-8fa2-07c950be9c6d}")   ; IAudioSessionControl2
                    pid := 0, state := 0
                    ComCall(3, control2, "int*", &state)   ; GetState
                    ComCall(14, control2, "uint*", &pid)   ; GetProcessId
                    if state = 1 && IsClaudeProcess(pid)   ; AudioSessionStateActive
                        return ComObjQuery(control, "{C02216F6-8C67-4B5B-9D00-D008E73E0064}")   ; IAudioMeterInformation
                } finally {
                    ObjRelease(control)
                }
            }
        } finally {
            ObjRelease(sessions)
        }
    } finally {
        ObjRelease(manager)
    }
    return 0
}

IsClaudeProcess(pid) {
    try return pid && ProcessGetName(pid) = "claude.exe"
    return false
}

; Current peak sample of the stream, 0.0–1.0.
MeterPeak(meter) {
    peak := 0.0
    ComCall(3, meter, "float*", &peak)   ; GetPeakValue
    return peak
}

GuidBuffer(text) {
    guid := Buffer(16)
    DllCall("ole32\CLSIDFromString", "wstr", text, "ptr", guid, "hresult")
    return guid
}
