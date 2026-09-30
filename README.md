# Voice Transcriber

Talk instead of type, in any app. Press the hotkey, say what you want, press it again,
and your words are typed wherever your cursor is. Transcription is done by OpenAI
(`gpt-transcribe`) using your own API key.

|  | macOS | Windows |
|---|---|---|
| Start / stop dictating | **Option+Space** | **Ctrl+Alt+Space** (changeable in Settings) |
| Throw the recording away | Esc | Esc |
| While recording: also keep it as a note | Option+N | Ctrl+Alt+N |
| While idle: open your notes | Option+N | Ctrl+Alt+N |
| Notes and Settings | menu bar mic icon | tray mic icon (bottom-right) |

- A small black pill at the top of the screen while it listens, naming the microphone in use
- **Settings**: spelling fixes ("Chat GPT → ChatGPT"), names it should recognise (people,
  companies, products), model, language, paste on/off, and your key. Changes save automatically.
- macOS: the menu bar icon shows which mic the next recording will use; headsets are preferred
  automatically and nearby iPhones are never picked. Windows: pick a mic in Settings, or leave
  it on the Windows default.

macOS 13 or later (Apple Silicon or Intel), or Windows 10/11.

## 1. Get an OpenAI API key

A ChatGPT subscription (Plus/Pro) does **not** include this. The API is a separate
pay-as-you-go account.

1. Sign up or log in at [platform.openai.com](https://platform.openai.com).
2. Add credit on the [billing page](https://platform.openai.com/settings/organization/billing)
   ("Add payment details", then add credit). The API is prepaid; $5 is plenty to start.
3. Create a key at [platform.openai.com/api-keys](https://platform.openai.com/api-keys):
   **Create new secret key**, name it "Voice Transcriber", copy it (it starts with `sk-`).
   It is shown only once.

Cost: about $0.0045 per minute of talking (OpenAI's price at the time of writing), so $5 is
roughly 18 hours of dictation. The key is stored only on your computer.

## 2. Install

**With Claude Code (easiest, either system):** open Claude Code in any folder and say:

> Install Voice Transcriber from https://github.com/MattFlowapt/voice-transcriber

Claude follows [CLAUDE.md](CLAUDE.md) and does the rest.

### macOS by hand

1. Download `VoiceTranscriber.zip` from the
   [latest release](https://github.com/MattFlowapt/voice-transcriber/releases/latest) and unzip it.
2. macOS calls downloaded apps "damaged" and blocks them. It isn't damaged. Open Terminal,
   type `xattr -cr ` (with a trailing space), drag the unzipped `VoiceTranscriber` folder onto
   the window, and press Return.
3. Double-click `Install.command` and paste your key when asked (or press Return and add it
   later in Settings).
4. Click **Allow** on the microphone prompt, and switch **VoiceTranscriber** on in the
   Accessibility settings window that opens. That is what lets it type for you; without it,
   your words are only copied to the clipboard.

### Windows by hand

1. On this page click **Code → Download ZIP**, unzip it, and open the `windows` folder.
2. Double-click **Install.cmd**. It installs Python if needed (via winget), the app, and a
   Start-up shortcut, then asks for your key (or press Enter and add it later in Settings).
   If Windows SmartScreen warns about the file, click **More info → Run anyway**.
3. If Windows asks about the microphone, allow it (Settings → Privacy & security →
   Microphone → "Let desktop apps access your microphone").
4. Test everything: the installer prints a `--check` command at the end. Run it and say
   something when asked.

Both versions start automatically at login.

## Troubleshooting

| Problem | Fix |
|---|---|
| macOS: "Damaged and can't be opened" | Step 2 of the macOS install wasn't done, or was done on the wrong folder |
| "Add your OpenAI key in Settings" | Tray / menu bar mic → Settings… → Recording → OpenAI key → Add |
| macOS: it says "Copied" instead of typing | System Settings → Privacy & Security → Accessibility → switch on VoiceTranscriber |
| Error mentioning 401 / 429 | 401: the key is wrong, so paste it again. 429: the account has no credit left |
| The hotkey does nothing | Another app uses it (macOS: ChatGPT's desktop app uses Option+Space). Windows: change it in Settings |
| Windows: nothing pastes into one particular app | That app runs as administrator; Windows blocks other apps from typing into it. The text is still on the clipboard |

Logs: macOS `~/Library/Logs/voice-transcriber.log`; Windows
`%LOCALAPPDATA%\VoiceTranscriber\voice-transcriber.log`.

## Privacy

Recordings are sent to OpenAI for transcription and aren't kept on your computer. Nothing
else leaves it. Notes and settings stay local (macOS `~/.config/voice-transcriber/`, Windows
`%APPDATA%\voice-transcriber\`).

## Build from source (macOS)

Needs the Xcode command-line tools (`xcode-select --install`).

```bash
./setup-codesign.sh   # once: a local signing certificate, so the Accessibility permission survives rebuilds
./build.sh            # builds VoiceTranscriber.app in this folder
```

Then copy `VoiceTranscriber.app` to `/Applications`. The whole Mac app is one Swift file,
`VoiceTranscriber.swift`. The Windows app is one Python file, `windows/voice_transcriber.py`.

## Found a problem? Fixed one?

Pull requests are very welcome, especially for the Windows version, which is new.

- **Fixed something?** Fork the repo, make the change, and open a pull request with a line
  on what was wrong and how you tested it. If Claude fixed it for you, just ask Claude to
  "send this fix as a pull request to MattFlowapt/voice-transcriber".
- **Found a bug but no fix?** [Open an issue](https://github.com/MattFlowapt/voice-transcriber/issues)
  with your system (macOS or Windows version), what you did, what happened, and the last
  lines of the log (Windows: also the output of `--check`).
- **Never paste your OpenAI key**, `config.json` or your notes into an issue or pull request.

## License

MIT (see [LICENSE](LICENSE)).
