#!/usr/bin/env bash
# Build Tessera for the iPhone and install it, as one of two apps:
#
#   install.sh claude    "Tessera",       com.jalenedusei.tessera        (the usual app)
#   install.sh codex     "Tessera Codex", com.jalenedusei.tessera.codex  (+ .widgets, .share)
#
# Two bundle ids are two icons on the phone, each with its own settings and
# its own wall address, so Codex's build of the app and Claude's can sit
# side by side and be tried against whichever wall software is live
# (pi/switch.sh). Run it from a checkout of the branch whose app you want.
#
# The ordinary app is built exactly as the project says. The Codex one takes
# its identifiers from Tools/codex.xcconfig: the project has two app
# extensions (widgets, share), and an extension's identifier must start with
# its app's, so a blanket override on the command line gave all three the
# same id and the phone refused the install ("DuplicateIdentifier"). The
# xcconfig gives each target its own. The Codex variant's app group (if the
# widgets share data through one) is not renamed; that is fine for trying
# the app, and a limitation to know about.
#
# Everything is by absolute path on purpose: xcodebuild and devicectl have
# been run from the wrong directory before when a cd raced another command.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"                       # tessera/
DEVICE="${DEVICE:-17BC0590-3932-52E0-A544-F4E27375D28F}"     # the iPhone: xcrun devicectl list devices

case "${1:-claude}" in
  claude) NAME="Tessera";       EXTRA=() ;;
  codex)  NAME="Tessera Codex"; EXTRA=(-xcconfig "$HERE/Tools/codex.xcconfig") ;;
  *) echo "usage: install.sh [claude|codex]"; exit 2 ;;
esac
DERIVED="$HOME/Library/Developer/Xcode/DerivedData/Tessera-${1:-claude}"

echo ">>> building $NAME"
xcodebuild -project "$HERE/Tessera.xcodeproj" -scheme Tessera -configuration Debug \
  -destination "id=$DEVICE" -derivedDataPath "$DERIVED" -allowProvisioningUpdates \
  "${EXTRA[@]}" build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | tail -n 12

APP="$DERIVED/Build/Products/Debug-iphoneos/Tessera.app"
[ -d "$APP" ] || { echo ">>> no app at $APP"; exit 1; }
echo ">>> identifiers"
for f in "$APP/Info.plist" "$APP"/PlugIns/*.appex/Info.plist; do
  [ -f "$f" ] && echo "    $(basename "$(dirname "$f")"): $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$f")"
done
echo ">>> installing on the iPhone"
xcrun devicectl device install app --device "$DEVICE" "$APP" 2>&1 | grep -E "installed|ERROR|error" | head -n 3
echo ">>> $NAME is on the phone"
