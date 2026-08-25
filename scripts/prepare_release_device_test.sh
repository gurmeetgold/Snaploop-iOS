#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
TEAM_ID="${SNAPLOOP_TEAM_ID:-GPDH2M3AVZ}"

echo "Preparing SnapLoop Release device test (getsnaploop)"

echo "[1/4] Configure signing + regenerate project"
bash "$ROOT/scripts/configure_personal_team.sh" "$TEAM_ID"

echo "[2/4] Verify Face Engine model"
bash "$ROOT/scripts/verify_face_model_v5.sh"

echo "[3/4] Check new backend fallback"
node --check functions/bootstrap.js
node --check functions/identityBoundMatches.js

echo "[4/4] Deploy only the new matched-photo fallback"
firebase deploy --project getsnaploop --only functions:getMatchedThumbnail

echo "Opening Xcode. SnapLoop Run is configured as Release. Select your iPhone and press Run."
open SnapLoop.xcodeproj
