#!/bin/bash
# Double-click this to install Voice Transcriber. Nothing else needed.
# Also safe to run from a terminal or by Claude: OPENAI_KEY=sk-... ./Install.command
set -euo pipefail
cd "$(dirname "$0")"

# package.sh can substitute a key here. Left as-is = ask for it (or skip it).
EMBEDDED_KEY="__OPENAI_KEY__"

APP="VoiceTranscriber.app"
DEST="/Applications/$APP"
LABEL="com.flowapt.voice-transcriber"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
CONFIG_DIR="$HOME/.config/voice-transcriber"

# Only wait for Return when a person is actually looking at a Terminal window.
pause() { if [ -t 0 ]; then read -r -p "  Press return to close this window." _ || true; fi; }

echo
echo "  Voice Transcriber — installer"
echo "  ============================="
echo

if [ ! -d "$APP" ]; then
  echo "  ERROR: $APP is not next to this installer."
  echo "  Unzip the whole folder first, then run Install.command from inside it."
  pause; exit 1
fi

# macOS quarantines anything downloaded; without this the app is blocked.
echo "  → Clearing the download quarantine flag"
xattr -cr . 2>/dev/null || true

echo "  → Installing to /Applications"
if [ -d "$DEST" ]; then
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  pkill -x VoiceTranscriber 2>/dev/null || true
  rm -rf "$DEST"
fi
cp -R "$APP" /Applications/

NO_KEY=0
mkdir -p "$CONFIG_DIR"
if [ ! -f "$CONFIG_DIR/config.json" ]; then
  KEY="${OPENAI_KEY:-}"
  if [ -z "$KEY" ] && [ "$EMBEDDED_KEY" != "__OPENAI_KEY__" ]; then KEY="$EMBEDDED_KEY"; fi
  if [ -z "$KEY" ] && [ -t 0 ]; then
    echo
    echo "  The app transcribes with OpenAI, so it needs your OpenAI API key"
    echo "  (READ-ME-FIRST.txt explains how to get one). It is stored only on this Mac."
    echo "  Paste it and press Return, or just press Return to add it later in Settings."
    echo
    read -r -p "  OpenAI API key: " KEY || true
  fi
  KEY="$(printf '%s' "$KEY" | tr -d '[:space:]')"
  # Escape backslashes and quotes so no key can break the JSON. (No python here:
  # on a Mac without developer tools, /usr/bin/python3 only asks to install them.)
  KEY_JSON="${KEY//\\/\\\\}"
  KEY_JSON="${KEY_JSON//\"/\\\"}"
  cat > "$CONFIG_DIR/config.json" <<EOF
{
  "openaiKey": "$KEY_JSON",
  "model": "gpt-transcribe",
  "autoPaste": true,
  "maxSeconds": 300,
  "vocabulary": ["Claude", "ChatGPT", "OpenAI"],
  "replacements": { "Chat GPT": "ChatGPT" }
}
EOF
  chmod 600 "$CONFIG_DIR/config.json"
  if [ -n "$KEY" ]; then echo "  → Key saved"; else NO_KEY=1; echo "  → No key yet (add it in Settings, see below)"; fi
else
  echo "  → Existing settings kept ($CONFIG_DIR/config.json)"
fi

echo "  → Setting it to start automatically at login"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>/usr/bin/open</string>
		<string>-W</string>
		<string>$DEST</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>LimitLoadToSessionType</key>
	<string>Aqua</string>
	<key>StandardOutPath</key>
	<string>$HOME/Library/Logs/voice-transcriber.log</string>
	<key>StandardErrorPath</key>
	<string>$HOME/Library/Logs/voice-transcriber.log</string>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
for i in 1 2 3 4 5; do launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null && break; sleep 1; done

echo
echo "  Installed and running. Look for the small microphone icon in your menu bar."
echo
if [ "$NO_KEY" = 1 ]; then
  echo "  ADD YOUR OPENAI KEY: click the menu bar microphone → Settings… → Recording"
  echo "  → OpenAI key → Add, paste it, press Return."
  echo
fi
echo "  TWO PERMISSIONS ARE NEEDED:"
echo "   1. Microphone    → click Allow when macOS asks (the first time you record)."
echo "   2. Accessibility → switch this on yourself. The settings window is opening now:"
echo "      find VoiceTranscriber and turn it ON. (Without it your words are copied to"
echo "      the clipboard instead of typed in.)"
echo
echo "  THEN: press  Option + Space  anywhere, talk, press it again."
echo
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" 2>/dev/null || true
pause
