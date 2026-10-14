# Claude Dictate Hotkey

AutoHotkey v2 (64-bit) tool that gives the Claude desktop app (Windows) a dictation hotkey by
pressing the composer's Dictate button through Windows UI Automation. Unofficial; not affiliated
with Anthropic.

## Files

- `ClaudeDictateHotkey.ahk`: hotkey, stop logic, silence monitor, countdown overlay, settings GUI
- `ClaudeUia.ahk`: raw-COM UI Automation helpers (find button/composer, read state, click)
- `build.ps1`: builds `dist\` (exe, portable zip, installer, SHA256SUMS); version comes from
  `;@Ahk2Exe-SetVersion` in the main script
- `installer\ClaudeDictateHotkey.iss`: Inno Setup 7 per-user installer; never change `AppId`
- `assets\`: icon and warning sounds (embedded via `FileInstall` when compiled)
- `CHANGELOG.md` + `docs\history\`: version history with illustrative mockups and measured charts

## Hard-won facts (don't re-learn these)

- Match the button by name, never by automation ID (React IDs change): `Dictate`,
  `Press and hold to record` (Claude's hold mode), `Stop dictation` (recording). English UI only.
- Filter by ControlType Button; `Group` elements share the names.
- Raw COM: use `GetCurrentPattern` + QueryInterface (`GetCurrentPatternAs` returns null here).
  Toggle pattern is intermittent → fall back to LegacyIAccessible `DoDefaultAction`.
- Claude rebuilds the button on every state change → element refs go stale (`0x80040201`).
  Always go through `WithDictateButton` (fresh lookup + retry).
- Claude timing: ~2.1 s restart cooldown after a stop (clicks are queued); stops within ~0.7 s of a
  recording starting are dropped or delayed. All stops go through `StopReliably`.
- Silence = no change in the composer text (Claude streams the transcript live). Mic meters were
  rejected (device unknown).
- Layout changes break geometry silently. Since Claude 2.37337 the mic sits at the right end of the
  text row and "Auto" is in a row below the box; before, the mic was in a row below the text.
  `FindComposer` (Edit spanning the mic, vertically closest), `FindComposerBox` (raw-view ancestor
  enclosing both with padding) and `FindCountdownTextPos` (leftmost button under the box) are
  layout-agnostic. No composer → silence stop is skipped, never assumed.
- `ScanTick` detects any recording by reading kept button references (~0.5 ms each); a full
  search costs ~400 ms in long conversations, so it only re-searches every 20 s or on a stale ref.
  Measured: ~4 % wall time at 10 s re-search while Claude is active.
- UIA rects are physical pixels; the script runs per-monitor DPI aware. Keep it that way.
- Detect Claude by window (`ahk_exe claude.exe ahk_class Chrome_WidgetWin_1`); the Claude Code
  CLI is also `claude.exe`.
- Since Claude 2.37337 (2026-10) there is a native dictation shortcut (focused-only, toggle or hold).
  The button's UIA `AcceleratorKey` reports `Shift+F10`, not the configured key; it can't be read.

## Working rules

- Validate syntax: `"C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe" /ErrorStdOut /validate ClaudeDictateHotkey.ahk`
- Don't launch the script or exe from an agent shell: keyboard hooks fail in the sandbox and
  screen capture returns blank. UIA probes that don't use hotkeys are fine; ask the user to run
  hotkey, GUI and visual tests.
- Probes that click Dictate turn the user's microphone on; say so before running them.
- Build: `.\build.ps1 -Ahk2Exe <path>\Ahk2Exe.exe` (uncompressed on purpose: fewer antivirus
  false positives). `dist\` is ignored.
- Branches: feature branches off `dev`, merged into `dev`; `main` for releases.
- Commit style: `[Action : Area] Summary`, single line, no AI attribution.

## Project notes (outside the repo, in the parent folder)

Keep these current as part of any change; don't wait to be asked:

- `DEVLOG.md`: append a short dated entry for each decision, measurement, fix or reversal
  (evidence, not assumptions). Keep its `Open` section in sync: remove done items, add new ones.
- `PUBLISH_CHECKLIST.md`: tick items when done; add new pre-publish work; rewrite items whose
  plan changed.
- `SIGNPATH_PLAN.md`: update when the version, release, CI workflow or signing status changes.

In the repo, add user-visible changes to `CHANGELOG.md` under `Unreleased`.

Before handing off, check all of these against what just changed and mention any updates made.
