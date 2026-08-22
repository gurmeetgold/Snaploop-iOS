#!/usr/bin/env bash
set -euo pipefail

: "${APPLE_TEAM_ID:?Set APPLE_TEAM_ID to your Apple Developer Team ID}"
: "${APP_STORE_URL:?Set APP_STORE_URL to the final MyPicsRoom App Store URL}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMPLATE="$ROOT/hosting/apple-app-site-association.template.json"
AASA="$ROOT/hosting/public/apple-app-site-association"
INDEX="$ROOT/hosting/public/index.html"

if ! [[ "$APPLE_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]]; then
  echo "APPLE_TEAM_ID must be a 10-character Apple Team ID." >&2
  exit 1
fi

if ! [[ "$APP_STORE_URL" =~ ^https://apps\.apple\.com/ ]]; then
  echo "APP_STORE_URL must be an https://apps.apple.com/ URL." >&2
  exit 1
fi

python3 - "$TEMPLATE" "$AASA" "$APPLE_TEAM_ID" <<'PY'
import pathlib, sys
src, dst, team = sys.argv[1:]
text = pathlib.Path(src).read_text()
pathlib.Path(dst).write_text(text.replace("__TEAM_ID__", team))
PY

python3 - "$INDEX" "$APP_STORE_URL" <<'PY'
import pathlib, sys, re
path, url = sys.argv[1:]
p = pathlib.Path(path)
text = p.read_text()
text, count = re.subn(r'const APP_STORE_URL = "[^"]*";', f'const APP_STORE_URL = "{url}";', text)
if count != 1:
    raise SystemExit("Could not locate APP_STORE_URL assignment")
p.write_text(text)
PY

python3 -m json.tool "$AASA" >/dev/null

echo "Rendered: $AASA"
echo "Configured App Store fallback in: $INDEX"
