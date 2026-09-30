# Voice Transcriber: install instructions for Claude

Push-to-talk dictation via OpenAI, for **macOS** (a native Swift app) and **Windows** (a
Python app in `windows/`). When the user asks you to install it, first check which system
you're on, then follow that section.

**For both:** ask whether they already have an OpenAI API key. If not, walk them through
"1. Get an OpenAI API key" in README.md. A ChatGPT subscription does not include API
access. Never print the key back or write it anywhere except where the installer puts it.
If they'd rather not paste the key into chat, install without it: the app then says "Add
your OpenAI key in Settings" and opens Settings → Recording for them to paste it themselves.

## macOS

1. `sw_vers -productVersion` must be 13 or later.
2. Download and un-quarantine the prebuilt app (no developer tools needed):
   ```bash
   cd "$(mktemp -d)"
   curl -fsSL -o VoiceTranscriber.zip https://github.com/MattFlowapt/voice-transcriber/releases/latest/download/VoiceTranscriber.zip
   unzip -q VoiceTranscriber.zip && xattr -cr VoiceTranscriber
   ```
3. Install: `OPENAI_KEY='<their key>' ./VoiceTranscriber/Install.command`. This copies the app
   to /Applications, writes `~/.config/voice-transcriber/config.json` (chmod 600), installs a
   login LaunchAgent and starts the app. An existing config.json is kept.
4. Permissions are the user's job (you can't grant them). Tell them to click **Allow** on the
   Microphone prompt the first time they record, and to switch **VoiceTranscriber** on in
   System Settings → Privacy & Security → Accessibility (the installer opens that pane).
   Without Accessibility, text is only copied to the clipboard, not typed.
5. Verify: `tail -20 ~/Library/Logs/voice-transcriber.log` shows `hotkey registered: ⌥Space`
   and `VoiceTranscriber running`. Ask them to press Option+Space, say a sentence, and press
   it again; the log shows `delivered … chars` on success.

Restart: `launchctl kickstart -k gui/$(id -u)/com.flowapt.voice-transcriber`. Uninstall:
`launchctl bootout gui/$(id -u)/com.flowapt.voice-transcriber; rm -rf
/Applications/VoiceTranscriber.app ~/Library/LaunchAgents/com.flowapt.voice-transcriber.plist`.
To build from source instead: `./setup-codesign.sh` once, then `./build.sh`, copy the built
app over `/Applications/VoiceTranscriber.app`, restart. After the first build signed with
their own certificate, Accessibility has to be switched on again once.

## Windows

1. Get the code (PowerShell):
   ```powershell
   $d = Join-Path $env:TEMP 'voice-transcriber'; Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue
   Invoke-WebRequest https://github.com/MattFlowapt/voice-transcriber/archive/refs/heads/main.zip -OutFile "$d.zip"
   Expand-Archive "$d.zip" $d -Force; $w = Join-Path $d 'voice-transcriber-main\windows'
   ```
2. Install: `powershell -NoProfile -ExecutionPolicy Bypass -File "$w\install.ps1" -Key '<their key>'`
   (or omit `-Key`). It installs Python 3.12 with winget if there's no Python 3.9+, pip-installs
   `requirements.txt` for the user, copies `voice_transcriber.py` to
   `%LOCALAPPDATA%\VoiceTranscriber`, writes `%APPDATA%\voice-transcriber\config.json` (kept
   if it exists), adds a Start-up shortcut (pythonw, no console), and starts it.
3. Run the self-test and have the user speak when it says so:
   `python "$env:LOCALAPPDATA\VoiceTranscriber\voice_transcriber.py" --check`
   (use the Python path the installer printed). It checks packages, the key, the mic (a
   3-second recording) and a real transcription, and lists anything to fix.
4. Ask them to press **Ctrl+Alt+Space** in an app like Notepad, say a sentence, and press it
   again. Check `%LOCALAPPDATA%\VoiceTranscriber\voice-transcriber.log` for `delivered … chars`.
5. Mic privacy: if the check records silence, Settings → Privacy & security → Microphone →
   "Let desktop apps access your microphone" must be on.

**The Windows version was written and tested on a Mac (logic, Settings, Notes and a real
transcription) but has not yet run on a real Windows PC.** If anything fails (install, hotkey,
tray icon, recording, paste, pill), don't stop at reporting it:
- read the log and the `--check` output, find the cause, and fix `voice_transcriber.py` (or
  `install.ps1`) so it works on this machine;
- keep the behaviour and the config.json format the same (hotkeys, tray menu, Settings tabs,
  spelling fixes, notes.json), and keep it one file with the same packages where possible;
- deploy the fix by re-running `install.ps1` (it replaces the installed copy and restarts
  the app), then repeat steps 3 and 4;
- tell the user what you changed and why.

Restart on Windows: re-run `install.ps1`, or quit from the tray icon and start the "Voice
Transcriber" shortcut in the Start-up folder. Uninstall: quit from the tray, then delete
`%LOCALAPPDATA%\VoiceTranscriber` and `Voice Transcriber.lnk` in
`shell:startup` (leave `%APPDATA%\voice-transcriber` unless they want their settings and
notes gone).
