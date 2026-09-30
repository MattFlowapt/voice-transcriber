#!/bin/bash
# Builds VoiceTranscriber.app and (re)starts the launchd agent. Run from anywhere.
set -euo pipefail
cd "$(dirname "$0")"

APP="VoiceTranscriber.app"
PLIST_LABEL="com.flowapt.voice-transcriber"
AGENT_PLIST="$HOME/Library/LaunchAgents/$PLIST_LABEL.plist"

echo "==> Compiling"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 VoiceTranscriber.swift -o "$APP/Contents/MacOS/VoiceTranscriber"
cp Info.plist "$APP/Contents/Info.plist"

# A stable identity (see setup-codesign.sh) keeps macOS's Accessibility grant
# across rebuilds; ad-hoc signing invalidates it every single time.
#
# Resolve by SHA-1 hash, not by name: a self-signed cert lists as
# CSSMERR_TP_NOT_TRUSTED (so `find-identity -v` hides it) yet signs perfectly,
# and duplicate certs of the same name make signing by name ambiguous.
CERT_NAME="Flowapt Local Codesign"
CERT_HASH="$(security find-identity -p codesigning 2>/dev/null \
  | grep "$CERT_NAME" | head -1 | awk '{print $2}')"

if [ -n "$CERT_HASH" ]; then
  echo "==> Code signing with '$CERT_NAME' ($CERT_HASH) — permission survives rebuilds"
  codesign --force --sign "$CERT_HASH" "$APP"
else
  echo "==> Ad-hoc code signing"
  echo "    NOTE: Accessibility (auto-paste) must be re-granted after every rebuild."
  echo "    Run ./setup-codesign.sh once to stop that happening."
  codesign --force --sign - "$APP"
fi

if [ -f "$AGENT_PLIST" ]; then
  echo "==> Restarting launchd agent"
  launchctl bootout "gui/$(id -u)/$PLIST_LABEL" 2>/dev/null || true
  # the agent launches via `open`, so the app itself is a separate process — kill it too
  pkill -x VoiceTranscriber 2>/dev/null || true
  # bootout is async — retry bootstrap until launchd finishes tearing down the old job
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if launchctl bootstrap "gui/$(id -u)" "$AGENT_PLIST" 2>/dev/null; then
      echo "==> Agent restarted"
      break
    fi
    if [ "$i" = "10" ]; then
      echo "ERROR: could not bootstrap agent after 10 tries" >&2
      exit 1
    fi
    sleep 1
  done
else
  echo "==> No launchd agent installed yet (see install.sh)"
fi

echo "==> Done: $(pwd)/$APP"
