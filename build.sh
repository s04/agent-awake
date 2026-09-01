#!/bin/bash
# Build, bundle, sign, and (by default) install + relaunch AgentAwake.
#   bash build.sh [version]              version defaults to latest git tag, else 0.0.0
#   INSTALL=0 bash build.sh 1.2.0        build only (used by CI)
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)"   real signing; default is ad-hoc
#   NOTARY_PROFILE=agentawake            notarize + staple (needs SIGN_IDENTITY; set up with
#                                        `xcrun notarytool store-credentials agentawake`)
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:-}"
[[ -z "$VERSION" ]] && VERSION="$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)"
[[ -z "$VERSION" ]] && VERSION=0.0.0

APP=build/AgentAwake.app
rm -rf build && mkdir -p "$APP/Contents/MacOS"
swiftc -O -o "$APP/Contents/MacOS/AgentAwake" main.swift -framework AppKit -framework ServiceManagement -framework UserNotifications
sed "s/__VERSION__/$VERSION/g" Info.plist > "$APP/Contents/Info.plist"

codesign --force --options runtime --sign "${SIGN_IDENTITY:--}" "$APP"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  ditto -c -k --keepParent "$APP" build/notarize.zip
  xcrun notarytool submit build/notarize.zip --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
fi

ditto -c -k --keepParent "$APP" build/AgentAwake.zip
echo "built build/AgentAwake.zip ($VERSION, signed as ${SIGN_IDENTITY:-ad-hoc})"

if [[ "${INSTALL:-1}" == 1 ]]; then
  osascript -e 'tell application "AgentAwake" to quit' >/dev/null 2>&1 || true
  rm -rf ~/Applications/AgentAwake.app
  ditto "$APP" ~/Applications/AgentAwake.app
  open ~/Applications/AgentAwake.app
  echo "installed and launched ~/Applications/AgentAwake.app"
fi
