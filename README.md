# Claude Dictate Hotkey

Global hotkey that toggles dictation in the Claude desktop app (Windows), which has no built-in dictation shortcut.

> Unofficial community tool. Not affiliated with or endorsed by Anthropic.

Default: **Ctrl+Shift+Space** toggles the composer's Dictate button, and dictation auto-stops after 90 seconds.
The hotkey only fires while the Claude window is focused; everywhere else the key combo behaves normally.

## Requirements

- AutoHotkey v2 (64-bit), installed at `C:\Program Files\AutoHotkey\v2\`
- Claude desktop app with **Dictation settings → Hold to record** turned **off** (toggle mode)
- Claude UI in English (the button is located by its accessible names `Dictate` / `Stop dictation`)

## Usage

- Start: double-click `ClaudeDictateHotkey.ahk`.
- Settings: double-click `Settings.bat`, or double-click / right-click the tray icon → **Settings...**
  - Type a hotkey in AutoHotkey syntax (`^` Ctrl, `+` Shift, `!` Alt, `#` Win) or click **Record new hotkey...** and press the combo.
  - Auto-stop timeout in seconds; `0` disables it.
  - **Start with Windows**: adds or removes a shortcut in your Startup folder.
  - Saved to `settings.ini` and applied immediately.
- The tray icon is shown only while a Claude window is open. With Claude closed, the script idles in the
  background and reappears when Claude opens, however Claude is launched.

## How it works

`ClaudeUia.ahk` uses Windows UI Automation to find the Dictate button in the active Claude window and
toggles it (Toggle pattern, falling back to the accessibility default action). No clicks at screen
coordinates and nothing inside Claude is modified. With several composers open (split view), a composer
that is already recording is stopped first; otherwise the one in the focused pane is used.

If an app update renames the button, the hotkey beeps and shows "Dictate button not found";
update `DICTATE_IDLE_NAME` / `DICTATE_ACTIVE_NAME` in `ClaudeUia.ahk`.

## License

[MIT](LICENSE)
