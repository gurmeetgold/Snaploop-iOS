#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

TEAM_ID="${SNAPLOOP_TEAM_ID:-GPDH2M3AVZ}"
ARCHIVE="$ROOT/build/SnapLoop-Internal.xcarchive"

cat <<EOF
SnapLoop Internal TestFlight
----------------------------
Target backend: getsnaploop (production)
Build config:   Release
Apple team:     $TEAM_ID
Tests:          skipped (run separately before public release)
EOF

for tool in xcodegen xcodebuild firebase node; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "ERROR: Required tool is not available: $tool" >&2
    exit 1
  fi
done

if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "WARNING: tracked local changes exist; this archive will include your local working tree."
fi

echo "[1/5] Configure Apple signing"
bash "$ROOT/scripts/configure_personal_team.sh" "$TEAM_ID"

echo "[2/5] Verify Face Engine v5 model"
bash "$ROOT/scripts/verify_face_model_v5.sh"

echo "[3/5] Check backend JavaScript syntax"
node --check functions/bootstrap.js
node --check functions/privacyHardening.js
node --check functions/stableFaceIdentity.js
node --check functions/faceIdentityMigration.js
node --check functions/identityBoundMatches.js
node --check functions/faceErasure.js

echo "[4/5] Create Release archive"
rm -rf "$ARCHIVE"
FIREBASE_SOURCE_FIRESTORE=1 xcodebuild \
  -project SnapLoop.xcodeproj \
  -scheme SnapLoop \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates \
  -quiet \
  archive

echo "[5/5] Deploy matching backend to getsnaploop"
firebase deploy --project getsnaploop --only functions,firestore:rules,storage,hosting

echo "Opening the Release archive in Xcode Organizer..."
open "$ARCHIVE"

cat <<'EOF'

READY FOR INTERNAL TESTFLIGHT
In Organizer: Distribute App > App Store Connect > Upload.
Do not upload if the Firebase deployment above failed.
EOF
