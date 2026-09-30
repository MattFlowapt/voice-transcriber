# Voice Transcriber

Talk instead of type, in any Mac app. Press **Option+Space**, say what you want, press it
again, and your words are typed wherever your cursor is. Transcription is done by OpenAI
(`gpt-4o-transcribe`) using your own API key.

- A small black pill at the top of the screen while it listens, naming the microphone in use
- A menu bar icon showing which mic the next recording will use (headsets are preferred
  automatically; iPhones nearby are never picked)
- **Option+N** while recording also saves the dictation as a note; Option+N when idle opens
  your notes (click one to copy)
- **Settings** (menu bar icon → Settings…): spelling fixes ("Chat GPT → ChatGPT"), names it
  should recognise, model, language, paste on/off, and your key. Changes save automatically.
- **Esc** throws a recording away

macOS 13 or later, Apple Silicon or Intel.

## 1. Get an OpenAI API key

A ChatGPT subscription (Plus/Pro) does **not** include this. The API is a separate
pay-as-you-go account.

1. Sign up or log in at [platform.openai.com](https://platform.openai.com).
2. Add credit on the [billing page](https://platform.openai.com/settings/organization/billing)
   ("Add payment details", then add credit). The API is prepaid; $5 is plenty to start.
3. Create a key at [platform.openai.com/api-keys](https://platform.openai.com/api-keys):
   **Create new secret key**, name it "Voice Transcriber", copy it (it starts with `sk-`).
   It is shown only once.

Cost: about $0.006 per minute of talking (OpenAI's price at the time of writing), so $5 is
roughly 14 hours of dictation. The key is stored only on your Mac
(`~/.config/voice-transcriber/config.json`, readable only by you).

## 2. Install

**With Claude Code (easiest):** open Claude Code in any folder and say:

> Install Voice Transcriber from https://github.com/MattFlowapt/voice-transcriber

Claude follows [CLAUDE.md](CLAUDE.md) and does the rest.

**By hand:**

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

It starts automatically at login.

## Troubleshooting

| Problem | Fix |
|---|---|
| "Damaged and can't be opened" | Step 2 above wasn't done, or was done on the wrong folder |
| "Add your OpenAI key in Settings" | Menu bar mic → Settings… → Recording → OpenAI key → Add |
| It says "Copied" instead of typing | System Settings → Privacy & Security → Accessibility → switch on VoiceTranscriber |
| Error mentioning 401 / 429 | 401: the key is wrong, so paste it again. 429: the account has no credit left |
| Option+Space does nothing | Another app uses the shortcut (ChatGPT's desktop app does by default); turn that off |

The log is at `~/Library/Logs/voice-transcriber.log`.

## Privacy

Recordings are sent to OpenAI for transcription and deleted locally afterwards. Nothing else
leaves your Mac. Notes and settings are stored in `~/.config/voice-transcriber/`.

## Build from source

Needs the Xcode command-line tools (`xcode-select --install`).

```bash
./setup-codesign.sh   # once: a local signing certificate, so the Accessibility permission survives rebuilds
./build.sh            # builds VoiceTranscriber.app in this folder
```

Then copy `VoiceTranscriber.app` to `/Applications`. The whole app is one Swift file,
`VoiceTranscriber.swift`.

## License

MIT (see [LICENSE](LICENSE)).
