#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_YML="$ROOT_DIR/project.yml"

TEAM_ID="${1:-}"

if [[ -z "$TEAM_ID" ]]; then
  # Apple Development certificate identities normally end with the 10-character
  # team identifier in parentheses. Use the first available development identity.
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

python3 - "$PROJECT_YML" "$TEAM_ID" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
team = sys.argv[2]
text = path.read_text()

# Replace an existing value if this helper was run before.
if re.search(r"(?m)^\s*DEVELOPMENT_TEAM:\s*.*$", text):
    text = re.sub(
        r"(?m)^(\s*)DEVELOPMENT_TEAM:\s*.*$",
        rf"\1DEVELOPMENT_TEAM: {team}",
        text,
        count=1,
    )
else:
    marker = "        CODE_SIGN_STYLE: Automatic\n"
    if marker not in text:
        raise SystemExit("Could not find CODE_SIGN_STYLE in project.yml")
    text = text.replace(marker, marker + f"        DEVELOPMENT_TEAM: {team}\n", 1)

path.write_text(text)
PY

echo "Configured SnapLoop DEVELOPMENT_TEAM=$TEAM_ID in project.yml"

if command -v xcodegen >/dev/null 2>&1; then
  cd "$ROOT_DIR"
  rm -rf SnapLoop.xcodeproj
  xcodegen generate
  echo "Regenerated SnapLoop.xcodeproj. Xcode should now keep this signing team."
else
  echo "xcodegen is not installed/in PATH. Run 'xcodegen generate' before opening Xcode."
fi
