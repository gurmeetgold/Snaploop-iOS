#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODEL_DIR="$ROOT/Sources/Resources/Models"
MODEL="$MODEL_DIR/SnapLoopFaceEmbedding.mlmodel"
LICENSE="$MODEL_DIR/AuraFace_LICENSE.md"

MODEL_URL="https://huggingface.co/RuiSumida/AuraFace-v1-CoreML/resolve/main/FaceEmbedding.mlmodel?download=true"
LICENSE_URL="https://huggingface.co/fal/AuraFace-v1/resolve/main/LICENSE.md?download=true"
# Pinned to the current FaceEmbedding.mlmodel artifact from the upstream model
# repository. Do not change this value merely to make a changed download pass;
# review the upstream revision and face benchmark first.
EXPECTED_MODEL_SHA256="9cb10bef2141a36619bb1fdbf1e0e14e2519c6da4b7e9b9969a4d67702d7122b"

mkdir -p "$MODEL_DIR"

echo "Downloading AuraFace v1 Core ML (~124 MB)..."
curl -L --fail --retry 4 --retry-delay 2 "$MODEL_URL" -o "$MODEL"

ACTUAL_MODEL_SHA256="$(shasum -a 256 "$MODEL" | awk '{print $1}')"
if [[ "$ACTUAL_MODEL_SHA256" != "$EXPECTED_MODEL_SHA256" ]]; then
  echo "ERROR: AuraFace model checksum mismatch." >&2
  echo "Expected: $EXPECTED_MODEL_SHA256" >&2
  echo "Actual:   $ACTUAL_MODEL_SHA256" >&2
  rm -f "$MODEL"
  exit 1
fi

echo "Verified AuraFace model SHA-256: $ACTUAL_MODEL_SHA256"

echo "Downloading AuraFace Apache-2.0 license..."
curl -L --fail --retry 4 --retry-delay 2 "$LICENSE_URL" -o "$LICENSE"

echo
echo "Installed and verified:"
echo "  $MODEL"
echo "  $LICENSE"
echo
echo "Next: rm -rf SnapLoop.xcodeproj && xcodegen generate"
