# Claude Dictate Hotkey

Global hotkey that toggles dictation in the Claude desktop app (Windows), which has no built-in dictation shortcut.

> Unofficial community tool. Not affiliated with or endorsed by Anthropic.

Default hotkey: **Ctrl+Space**. **Tap** it to start dictating and tap again to stop, or **hold** it to
record and release to stop. Dictation stops by itself after 10 seconds of silence, and after
15 minutes at most. The hotkey and both limits can be changed in [Settings](#usage).
Works whether Claude's own **Hold to record** dictation setting is on or off.
If you use an input method that switches on Ctrl+Space (e.g. Chinese or Japanese), pick another hotkey.
The hotkey only fires while the Claude window is focused; everywhere else the key combo behaves normally.

## Requirements

- Windows 10/11 (64-bit)
- Claude desktop app
- Claude UI in English (the button is located by its accessible names `Dictate` / `Press and hold to record` /
  `Stop dictation`)

## Install

Download from [Releases](https://github.com/AweGuider/Claude-Dictate-Hotkey/releases):

- **Installer** (`ClaudeDictateHotkey-<version>-setup.exe`): per-user install, no admin rights needed.
  Adds Start Menu entries for the app and its Settings, and optionally starts it with Windows.
- **Portable** (`ClaudeDictateHotkey-<version>-portable.zip`): unzip anywhere and run `ClaudeDictateHotkey.exe`.
- **From source**: install [AutoHotkey v2](https://www.autohotkey.com/) and run `ClaudeDictateHotkey.ahk`.

### Antivirus / SmartScreen warnings

Compiled AutoHotkey programs are often flagged as false positives, and the releases are not code-signed yet.
Some antivirus products (e.g. Avast) may also flag the installer, its temporary `setup.tmp`, and the uninstaller.
Every release lists SHA256 hashes in `SHA256SUMS.txt` so you can verify the download, and the source is in
this repository if you prefer to run the `.ahk` directly. False positives can be reported to
[Microsoft](https://www.microsoft.com/wdsi/filesubmission) and [Avast](https://www.avast.com/false-positive-file-form.php).

## Usage

- Settings: Start Menu → **Claude Dictate Hotkey Settings**, `Settings.bat` (portable/source), or
  double-click / right-click the tray icon → **Settings...**
  - Type a hotkey in AutoHotkey syntax (`^` Ctrl, `+` Shift, `!` Alt, `#` Win) or click **Record new hotkey...** and press the combo.
  - **Silence stop**: seconds without new dictated text before dictation stops; `0` disables it.
    Silence is detected from the transcript Claude writes into the message box, so background
    noise doesn't keep it running. Only applies to dictation started with the hotkey.
  - **Maximum dictation length** in seconds; `0` means unlimited.
  - **Start with Windows**: adds or removes a shortcut in your Startup folder.
  - Applied immediately and saved to `%APPDATA%\ClaudeDictateHotkey\settings.ini`. If a `settings.ini`
    exists next to the program, that one is used instead (portable mode).
- The tray icon is shown only while a Claude window is open. With Claude closed, the script idles in the
  background and reappears when Claude opens, however Claude is launched.

## Where it works

| Surface | Dictation shortcut |
| :- | :- |
| Claude desktop app, **Code** tab | This tool |
| Claude desktop app, **Chat** tab | This tool (same Dictate button) |
| Claude Code **CLI** in a terminal | Built in: run `/voice`, then hold `Space` (or `/voice tap` to toggle). Rebind via `voice:pushToTalk` in `~/.claude/keybindings.json`. See the [voice dictation docs](https://code.claude.com/docs/en/voice-dictation). |
| Claude Code **VS Code extension** | Built in (same docs page) |

This tool's hotkey does nothing in terminals. For the CLI, use its built-in `/voice` and pick a key your
terminal doesn't intercept: Windows Terminal, for example, uses `Ctrl+Shift+Space` for its new-tab menu.

## How it works

`ClaudeUia.ahk` uses Windows UI Automation to find the Dictate button in the active Claude window and
toggles it (Toggle pattern, falling back to the accessibility default action). No clicks at screen
coordinates and nothing inside Claude is modified. With several composers open (split view), a composer
that is already recording is stopped first; otherwise the one in the focused pane is used.

If an app update renames the button, the hotkey beeps and shows "Dictate button not found";
update `DICTATE_IDLE_NAME` / `DICTATE_ACTIVE_NAME` in `ClaudeUia.ahk`.

## Building

Requires [Ahk2Exe](https://github.com/AutoHotkey/Ahk2Exe/releases) and [Inno Setup](https://jrsoftware.org/isdl.php).

```powershell
.\build.ps1 -Ahk2Exe <path>\Ahk2Exe.exe
```

Outputs the exe, portable zip, installer and `SHA256SUMS.txt` to `dist\`. The version comes from the
`;@Ahk2Exe-SetVersion` line in `ClaudeDictateHotkey.ahk`. Ahk2Exe defaults to
`C:\Program Files\AutoHotkey\Compiler\Ahk2Exe.exe` (or `$env:AHK2EXE`); pass `-SkipInstaller` to skip Inno Setup.

## License

[MIT](LICENSE)
