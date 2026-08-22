#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

command -v xcodegen >/dev/null || { echo "xcodegen is required" >&2; exit 1; }
command -v xcodebuild >/dev/null || { echo "Xcode command-line tools are required" >&2; exit 1; }

rm -rf SnapLoop.xcodeproj
xcodegen generate

bash scripts/install_face_model_v5.sh
bash scripts/verify_face_model_v5.sh

FIREBASE_SOURCE_FIRESTORE=1 xcodebuild \
  -resolvePackageDependencies \
  -project SnapLoop.xcodeproj \
  -scheme SnapLoop

FIREBASE_SOURCE_FIRESTORE=1 xcodebuild \
  -project SnapLoop.xcodeproj \
  -scheme SnapLoop \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build

DEVICE_ID="$(xcrun simctl list devices available -j | python3 -c 'import json,sys; d=json.load(sys.stdin)["devices"]; print(next(x["udid"] for runtime in d.values() for x in runtime if x["name"].startswith("iPhone") and x.get("isAvailable", False)))')"

FIREBASE_SOURCE_FIRESTORE=1 xcodebuild \
  -project SnapLoop.xcodeproj \
  -scheme SnapLoop \
  -destination "platform=iOS Simulator,id=$DEVICE_ID" \
  CODE_SIGNING_ALLOWED=NO \
  test

echo "Phase 3 clean-clone verification passed."
