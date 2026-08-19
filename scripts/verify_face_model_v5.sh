#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODEL="$ROOT/Sources/Resources/Models/SnapLoopFaceEmbedding.mlmodel"
EXPECTED_MODEL_SHA256="9cb10bef2141a36619bb1fdbf1e0e14e2519c6da4b7e9b9969a4d67702d7122b"

if [[ ! -f "$MODEL" ]]; then
  echo "ERROR: Face model is missing: $MODEL" >&2
  echo "Run scripts/install_face_model_v5.sh first." >&2
  exit 1
fi

ACTUAL_MODEL_SHA256="$(shasum -a 256 "$MODEL" | awk '{print $1}')"
if [[ "$ACTUAL_MODEL_SHA256" != "$EXPECTED_MODEL_SHA256" ]]; then
  echo "ERROR: Face model SHA-256 mismatch." >&2
  echo "Expected: $EXPECTED_MODEL_SHA256" >&2
  echo "Actual:   $ACTUAL_MODEL_SHA256" >&2
  exit 1
fi

echo "Face model integrity OK: $ACTUAL_MODEL_SHA256"
