#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
TEAM_ID="${SNAPLOOP_TEAM_ID:-GPDH2M3AVZ}"

echo "Preparing SnapLoop Release device test (getsnaploop)"
echo "This command deploys the complete backend contract used by the Release app."
echo "A partial Functions deploy is unsafe for Change 4 because the client, matching callables,"
echo "Firestore rules, and Storage rules must move together."

echo "[1/4] Configure signing + regenerate project"
bash "$ROOT/scripts/configure_personal_team.sh" "$TEAM_ID"

echo "[2/4] Verify Face Engine model"
bash "$ROOT/scripts/verify_face_model_v5.sh"

echo "[3/4] Check all backend JavaScript"
for file in functions/*.js; do
  node --check "$file"
done

echo "[4/4] Deploy complete Release matching backend + security rules to getsnaploop"
firebase deploy --project getsnaploop --only functions,firestore:rules,storage

echo "Opening Xcode. SnapLoop Run is configured as Release. Select your physical iPhone and press Run."
open SnapLoop.xcodeproj
