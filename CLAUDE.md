# Voice Transcriber: install instructions for Claude

A macOS menu-bar app for push-to-talk dictation via OpenAI. When the user asks you to
install it:

1. **Check the Mac:** `sw_vers -productVersion` must be 13 or later.

2. **OpenAI key.** Ask whether they already have an OpenAI API key. If not, walk them
   through "1. Get an OpenAI API key" in README.md. A ChatGPT subscription does not
   include API access. Never print the key back or write it anywhere except where step 4
   puts it.

3. **Download and un-quarantine the prebuilt app** (no developer tools needed):
   ```bash
   cd "$(mktemp -d)"
   curl -fsSL -o VoiceTranscriber.zip https://github.com/MattFlowapt/voice-transcriber/releases/latest/download/VoiceTranscriber.zip
   unzip -q VoiceTranscriber.zip && xattr -cr VoiceTranscriber
   ```

4. **Install:** `OPENAI_KEY='<their key>' ./VoiceTranscriber/Install.command`
   This copies the app to /Applications, writes `~/.config/voice-transcriber/config.json`
   (chmod 600), installs a login LaunchAgent and starts the app. If the user prefers not
   to paste the key into chat, run it without `OPENAI_KEY`. The app then shows "Add your
   OpenAI key in Settings" and opens Settings → Recording, where they paste it themselves.
   An existing config.json is kept, never overwritten.

5. **Permissions are the user's job** (you can't grant them). Tell them to:
   - click **Allow** on the Microphone prompt the first time they record;
   - switch **VoiceTranscriber** on in System Settings → Privacy & Security →
     Accessibility (the installer opens that pane). Without it, text is only copied to
     the clipboard, not typed.

6. **Verify:** `tail -20 ~/Library/Logs/voice-transcriber.log` should show
   `hotkey registered: ⌥Space` and `VoiceTranscriber running`. Ask them to press
   Option+Space, say a sentence, and press it again. The log shows `delivered … chars`
   on success.

## Afterwards

- Spelling fixes, names, model, language, the key: menu bar mic → **Settings…** (saves
  automatically), or edit `~/.config/voice-transcriber/config.json`.
- Restart: `launchctl kickstart -k gui/$(id -u)/com.flowapt.voice-transcriber`
- Uninstall: `launchctl bootout gui/$(id -u)/com.flowapt.voice-transcriber; rm -rf
  /Applications/VoiceTranscriber.app ~/Library/LaunchAgents/com.flowapt.voice-transcriber.plist`
  (leave `~/.config/voice-transcriber` unless they want their settings and notes gone).

## Building from source instead

Needs the Xcode command-line tools. Run `./setup-codesign.sh` once, then `./build.sh`, then
replace `/Applications/VoiceTranscriber.app` with the built `VoiceTranscriber.app` and run
the restart command. Note for the user: after the first build signed with their own
certificate, Accessibility has to be switched on again once.
