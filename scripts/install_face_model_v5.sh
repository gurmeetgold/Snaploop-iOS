#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODEL_DIR="$ROOT/Sources/Resources/Models"
MODEL="$MODEL_DIR/SnapLoopFaceEmbedding.mlmodel"
LICENSE="$MODEL_DIR/AuraFace_LICENSE.md"

MODEL_URL="https://huggingface.co/RuiSumida/AuraFace-v1-CoreML/resolve/main/FaceEmbedding.mlmodel?download=true"
LICENSE_URL="https://huggingface.co/fal/AuraFace-v1/resolve/main/LICENSE.md?download=true"

mkdir -p "$MODEL_DIR"

echo "Downloading AuraFace v1 Core ML (~124 MB)..."
curl -L --fail --retry 4 --retry-delay 2 "$MODEL_URL" -o "$MODEL"

echo "Downloading AuraFace Apache-2.0 license..."
curl -L --fail --retry 4 --retry-delay 2 "$LICENSE_URL" -o "$LICENSE"

echo
echo "Installed:"
echo "  $MODEL"
echo "  $LICENSE"
echo
echo "Local SHA-256 (record this in test notes):"
shasum -a 256 "$MODEL"
echo
echo "Next: rm -rf SnapLoop.xcodeproj && xcodegen generate"
