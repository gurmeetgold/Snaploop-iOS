# Face Engine v5 — device test

This branch replaces the aligned Apple Vision feature-print fallback with an
identity-trained AuraFace Core ML embedding model.

Pipeline:

`photo -> Vision landmarks -> canonical 5-point 112x112 alignment -> AuraFace -> 512-D normalized embedding -> multi-template decision`

## Install the evaluation model

```bash
cd /Users/gurmeet/Documents/GC-Workspace/GC-SnapLoop/Snaploop-iOS
chmod +x scripts/install_face_model_v5.sh
./scripts/install_face_model_v5.sh
```

The downloaded model is intentionally ignored by Git because it is ~124 MB.
The model source is `RuiSumida/AuraFace-v1-CoreML`, converted from
`fal/AuraFace-v1`. The upstream model/repository is Apache-2.0. This is still an
evaluation build until SnapLoop's own genuine/impostor benchmark passes.

## Regenerate and build

```bash
rm -rf SnapLoop.xcodeproj
xcodegen generate

FIREBASE_SOURCE_FIRESTORE=1 \
xcodebuild \
  -project SnapLoop.xcodeproj \
  -scheme SnapLoop \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  build 2>&1 | tee /tmp/snaploop-build.log
```

If the build fails:

```bash
grep -n "error:" /tmp/snaploop-build.log
```

## Real-device test

v5 is a new embedding space, so redo Face Setup after installing the model.
The Face Test screen must show:

- Engine: `auraface-v1-coreml-fp16`
- Model version: `5`
- Threshold: approximately `0.520` unless v5 Remote Config keys are changed

If it shows `unknown`, the Core ML model did not get bundled into the app.

Test the same genuine photos used against v4, then at least 5-10 wrong-person
photos. Do not tune the threshold from genuine photos alone.
