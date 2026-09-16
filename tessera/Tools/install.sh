#!/bin/bash
# Build an isolated app identity without changing the comparison checkout.
set -euo pipefail
variant=${1:-codex}
case "$variant" in codex|claude) ;; *) echo 'Usage: install.sh codex|claude [device-id]' >&2; exit 2;; esac
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
staging=$(mktemp -d /tmp/tessera-build.XXXXXX)
rsync -a --exclude 'build*' --exclude '.DS_Store' "$root/tessera/" "$staging/tessera/"
if [ "$variant" = codex ]; then
    python3 - "$staging/tessera" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
for path in root.rglob('*'):
    if path.suffix not in {'.swift', '.plist', '.entitlements', '.pbxproj'}:
        continue
    text = path.read_text()
    text = text.replace('com.jalenedusei.tessera', 'com.jalenedusei.tessera.codex')
    text = text.replace('tessera://', 'tessera-codex://')
    text = text.replace('callbackURLScheme: "tessera"', 'callbackURLScheme: "tessera-codex"')
    text = text.replace('url.scheme == "tessera"', 'url.scheme == "tessera-codex"')
    text = text.replace('<string>tessera</string>', '<string>tessera-codex</string>')
    if path.name == 'Info.plist':
        text = text.replace('<string>Tessera</string>', '<string>Tessera Codex</string>')
    path.write_text(text)
PY
fi
device=${2:-17BC0590-3932-52E0-A544-F4E27375D28F}
xcodebuild -project "$staging/tessera/Tessera.xcodeproj" -scheme Tessera \
    -configuration Debug -sdk iphoneos -destination 'generic/platform=iOS' \
    -derivedDataPath "$staging/derived" -allowProvisioningUpdates build \
    > "$staging/build.log" 2>&1 || { tail -80 "$staging/build.log"; exit 1; }
app="$staging/derived/Build/Products/Debug-iphoneos/Tessera.app"
xcrun devicectl device install app --device "$device" "$app"
echo "[$variant] Installed from $app; build log: $staging/build.log"
