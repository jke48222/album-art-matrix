#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT=${1:-/tmp/tessera-record-proof}
DEVICE=${SIMULATOR_UDID:-656AFBBD-1ED1-4828-9692-59467A1E70E1}
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
mkdir -p "$OUT"
xcrun swiftc -O -parse-as-library -sdk "$SDK" -target arm64-apple-ios18.0-simulator \
    "$ROOT/Tessera/Record.swift" "$ROOT/Tessera/RecordLabel.swift" "$ROOT/Tessera/Sleeve.swift" \
    "$ROOT/Tools/record/Proof.swift" -o "$OUT/RecordProof"
xcrun simctl spawn "$DEVICE" "$OUT/RecordProof" "$OUT"
