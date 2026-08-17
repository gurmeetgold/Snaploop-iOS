# SnapLoop Face Recognition — v4 rebuild (in-house, Phase 1)

## Root-cause analysis (read from the V3 code, not assumed)

The prompt's premise — "the descriptor isn't identity-trained" — is correct and
is the ceiling. But reading `VisionDevelopmentFaceDetectionService.swift` and
`FaceMatcher.swift` as they stood, there was a second, independently fixable
problem *underneath* it that was making the descriptor look even worse than its
true ceiling:

| Stage | V3 state | Problem |
|---|---|---|
| Detection | `VNDetectFaceRectangles` | OK for locating faces. |
| **Orientation** | Handler always ran at `orientation: .up` | **Camera-roll photos with EXIF rotation were fed in rotated.** A real bug. |
| **Crop** | 1.55× square around the raw face box | **No eye alignment.** Same person at two head angles → very different pixels → very different descriptors. |
| Descriptor | `VNGenerateImageFeaturePrint` | Generic image-similarity, not identity-trained. The ceiling. |
| Scoring | best 0.60 / second 0.27 / third 0.13 blend + margin | Reasonable, but calibrated against a descriptor with poor separation, so no blend rescues it. |
| Thresholds | hardcoded 0.90 / 0.04 margin | Guessed, not derived from genuine-vs-impostor data. |

So: **alignment + orientation were a floor problem, the descriptor is a ceiling
problem.** V3's own numbers (same-person best/second ~0.736/0.706, 0.798/0.751)
are consistent with both acting at once — poor descriptor *and* unaligned input.

## What this change delivers

A rebuilt pipeline behind the **existing `FaceDetectionService` seam**, so
scanning/matching/storage/UI are untouched:

```
image → detect + landmarks → geometric alignment → aligned 112px crop
      → FaceEmbeddingEngine (pluggable) → L2-normalized embedding → matcher
```

New files (`Sources/Services/FaceEngine/`):
- **`FaceEmbeddingEngine.swift`** — the seam the brief asked for. Detection and
  alignment are separated from the neural descriptor, so the embedding is
  swappable without touching the rest of the app (same pattern as `AuthService`).
- **`FaceAligner.swift`** — the real fix you can test today: bakes EXIF
  orientation upright, detects landmarks, and applies the 2-point (eye-based)
  similarity transform onto canonical positions in a square output. Done in
  UIKit top-left pixel space to avoid Core Image's flipped-origin alignment bugs.
- **`CoreMLFaceEmbeddingEngine.swift`** — production seam. Loads a bundled
  `SnapLoopFaceEmbedding.mlpackage` via Vision, discovers I/O from the model
  description (works with any ArcFace/MobileFaceNet export), returns nil if no
  model is bundled so the app falls back cleanly.
- **`AlignedVisionFeaturePrintEngine.swift`** — interim, DEV-ONLY. Same
  feature-print primitive, now over aligned crops. `isIdentityGrade == false`.
- **`PipelineFaceDetectionService.swift`** — composes aligner + engine; picks
  the Core ML model if bundled, else the aligned feature-print (DEBUG), else a
  not-ready service (release). Wired into `AppEnvironment.live()`.

Supporting:
- **`FaceCalibration.swift`** (+ tests) — derive thresholds from genuine vs
  impostor score distributions (FAR/FRR sweep, precision-first target-FAR
  point, EER, separation). Thresholds from data, not guesses. Negative testing
  (impostors) is first-class.
- **`FaceModelPolicy`** bumped to **v4** → forces re-enrollment, roster refresh,
  and re-scan (v3 descriptors are a different space and must never be compared
  to v4).
- **`tools/convert_face_model.py` + `tools/FACE_MODEL.md`** — how to produce the
  real `.mlpackage` and the licensing rules for doing so.

## The honest limitation

**No trained model binary is included, and one cannot be produced in the repo's
authoring environment** (no network / no coremltools). Until you run
`tools/convert_face_model.py` on a real checkout and add the resulting
`SnapLoopFaceEmbedding.mlpackage` to the SnapLoop target:

- DEBUG builds run the **aligned feature-print** — measurably better separation
  than V3 because of alignment + orientation, but **still not identity-grade**.
  Do not read a DEBUG pass as production accuracy.
- Release builds **refuse matching** (`isReadyForMatching == false`) rather than
  ship a dev descriptor — unchanged safety posture from V3.

Alignment will raise your same-person scores and lower some cross-person scores,
but the feature-print's *ceiling* only lifts when a real embedding model is
dropped into the Core ML seam. That drop-in requires no further app code.

## Privacy/safety controls preserved

On-device processing only; no raw trip images or bystander faces uploaded for
recognition; embeddings are L2-normalized descriptors, never raw frames; v4
versioning + forced re-enrollment; deletion/withdrawal path unchanged; no face
data in logs (only `String(describing:)` of errors, never embeddings). The
aligner holds no raw frames beyond the synchronous warp.

## Build / deploy

Pure Swift additions — no `.mlmodel` resource is declared in `project.yml` yet,
so **no `xcodegen` change is needed to build what's here**. When you add a real
model:
1. Produce `SnapLoopFaceEmbedding.mlpackage` (see `tools/FACE_MODEL.md`).
2. Add it under `Sources/` (or a `Resources/` group) so XcodeGen bundles it;
   run `xcodegen generate` and a clean build.
3. `CoreMLFaceEmbeddingEngine()` will find it automatically; bump
   `FaceModelPolicy.currentVersion` to 5 to force re-enrollment onto the real
   embedding space.

## What still needs on-device verification

I can't compile or run this (no Swift toolchain in the authoring env). The
alignment math, Vision landmark mapping, and Core ML I/O are written carefully
but need a real device/simulator run — especially: landmark→pixel coordinate
mapping across orientations, and the `imageCropAndScaleOption` behavior on the
aligned crop. The Face Test screen is the right place to eyeball aligned crops.
