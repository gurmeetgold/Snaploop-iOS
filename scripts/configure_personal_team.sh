#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LOCAL_SIGNING="$ROOT_DIR/Config/Signing.local.xcconfig"
TEAM_ID="${1:-}"

if [[ -z "$TEAM_ID" ]]; then
  TEAM_ID="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -nE 's/.*Apple Development:.*\(([A-Z0-9]{10})\).*/\1/p' \
    | head -n 1 || true)"
fi

if [[ ! "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]]; then
  cat <<'EOF'
Could not automatically find your Apple Development Team ID.

In Xcode, open Settings > Accounts, select your Apple ID / Personal Team, and
copy the 10-character Team ID. Then run:

  ./scripts/configure_personal_team.sh YOURTEAMID
EOF
  exit 1
fi

mkdir -p "$ROOT_DIR/Config"
cat > "$LOCAL_SIGNING" <<EOF
// Generated locally. Do not commit.
DEVELOPMENT_TEAM = $TEAM_ID
EOF

echo "Configured MyPicsTube DEVELOPMENT_TEAM=$TEAM_ID in Config/Signing.local.xcconfig"

if command -v xcodegen >/dev/null 2>&1; then
  cd "$ROOT_DIR"
  rm -rf SnapLoop.xcodeproj
  xcodegen generate
  echo "Regenerated SnapLoop.xcodeproj. Future XcodeGen runs will keep this Personal Team via the local xcconfig."
else
  echo "xcodegen is not installed/in PATH. Run 'xcodegen generate' before opening Xcode."
fi
