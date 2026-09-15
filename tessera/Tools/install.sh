#!/usr/bin/env bash
# Build Tessera for the iPhone and install it, as one of two apps:
#
#   install.sh claude    "Tessera",     com.jalenedusei.tessera      (the usual app)
#   install.sh codex     "Tessera Codex", com.jalenedusei.tessera.codex
#
# Two bundle ids are two icons on the phone, each with its own settings and
# its own wall address, so Codex's build of the app and Claude's can sit
# side by side and be tried against whichever wall software is live
# (pi/switch.sh). Run it from a checkout of the branch whose app you want.
#
# Everything is by absolute path on purpose: xcodebuild and devicectl have
# been run from the wrong directory before when a cd raced another command.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"                       # tessera/
DEVICE="${DEVICE:-17BC0590-3932-52E0-A544-F4E27375D28F}"     # the iPhone: xcrun devicectl list devices

case "${1:-claude}" in
  claude) ID="com.jalenedusei.tessera";     NAME="Tessera" ;;
  codex)  ID="com.jalenedusei.tessera.codex"; NAME="Tessera Codex" ;;
  *) echo "usage: install.sh [claude|codex]"; exit 2 ;;
esac
DERIVED="$HOME/Library/Developer/Xcode/DerivedData/Tessera-${1:-claude}"

echo ">>> building $NAME ($ID)"
xcodebuild -project "$HERE/Tessera.xcodeproj" -scheme Tessera -configuration Debug \
  -destination "id=$DEVICE" -derivedDataPath "$DERIVED" -allowProvisioningUpdates \
  PRODUCT_BUNDLE_IDENTIFIER="$ID" INFOPLIST_KEY_CFBundleDisplayName="$NAME" \
  build 2>&1 | grep -E "error:|warning: .*deprecated|BUILD SUCCEEDED|BUILD FAILED" | tail -n 12

APP="$DERIVED/Build/Products/Debug-iphoneos/Tessera.app"
[ -d "$APP" ] || { echo ">>> no app at $APP"; exit 1; }
echo ">>> installing on the iPhone"
xcrun devicectl device install app --device "$DEVICE" "$APP" 2>&1 | tail -n 3
echo ">>> $NAME is on the phone"
