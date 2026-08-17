# SnapLoop Face Engine v3 Foundation

This patch is the first commercial-oriented face architecture layer.

It DOES:
- replace one-selfie enrollment with a guided multi-angle camera flow;
- auto-capture high-quality center/side/tilted views;
- keep raw camera frames in memory only;
- store up to 5 mathematical templates per user;
- use multi-template scoring + ambiguity rejection;
- version everything as FaceProfile v3;
- record explicit biometric consent separately from templates;
- refresh v3 templates into existing event rosters;
- keep gallery enrollment only as a supplemental/fallback path;
- preserve the existing My Photos / Shared Album pipeline;
- keep the face engine behind a replaceable protocol.

It does NOT claim the temporary DEBUG Vision descriptor is commercial-grade
identity recognition. A licensed identity-trained face SDK/model still needs to
be plugged into the FaceDetectionService seam before App Store release.

## Why this architecture

The failure of the v2 test was expected:
generic image feature prints vary too much across distance, pose, glasses and
lighting.

v3 improves two independent layers:

1. ENROLLMENT
   - several poses instead of one selfie
   - capture quality gating
   - one-person-only guided scan
   - automatic frame selection
   - explicit consent

2. DECISION ENGINE
   - compare every detected face to several templates per person
   - blend best + supporting template scores
   - reject low-confidence matches
   - reject ambiguous best-vs-runner-up matches
   - continue rejecting tiny background faces

## Commercial engine bake-off

Do not ship downloaded research weights with unclear commercial rights.

Evaluate at least:
- Neurotechnology Face Verification / VeriLook
- Innovatrics iOS Face / IFace family

Selection criteria:
- iOS offline template extraction + matching
- 1:N or efficient small-roster matching
- PAD/liveness options
- template revocability/protection
- face quality + pose signals
- model footprint
- latency on recent iPhones
- performance on glasses, hats, beards, side pose, older photos, low light
- documented commercial license rights
- privacy / telemetry behavior
- pricing at 100 / 1k / 10k / 100k MAU

The adapter must implement SnapLoop's FaceDetectionService so the rest of the
app does not know which engine won.

## Benchmark protocol before choosing a vendor

Create a consented internal benchmark set.

For each consenting tester:
- 5 guided enrollment views
- 25+ positive trip photos:
  - front
  - left/right pose
  - glasses
  - sunglasses
  - hat
  - beard/no-beard if available
  - indoor/outdoor
  - strong/weak light
  - close selfie
  - group photo
  - full body / smaller face
- 100+ negative faces from other consenting testers

Measure:
- true accept rate at a fixed very-low false accept target
- false matches per 1,000 candidate comparisons
- false rejects by pose/accessory/face size
- latency per face
- memory / battery
- differences across skin tone / age / sex presentation where the consented
  sample permits meaningful analysis

Never tune only on one person.

## Install

Unzip over the current SnapLoop repo.

Then:

```bash
cd /Users/gurmeet/Documents/GC-Workspace/GC-SnapLoop/Snaploop-iOS

firebase deploy --only functions,firestore:rules

rm -rf SnapLoop.xcodeproj
xcodegen generate

rm -rf ~/Library/Developer/Xcode/DerivedData/SnapLoop-*

xcodebuild \
  -project SnapLoop.xcodeproj \
  -scheme SnapLoop \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  build 2>&1 | tee /tmp/snaploop-build.log
```

If build fails:

```bash
grep -n "error:" /tmp/snaploop-build.log
```

## Required v3 test

Existing v2 profiles are intentionally invalidated.

For each test user:
1. You -> Face Setup.
2. Review Face Match Consent.
3. Start Guided Face Scan on a REAL iPhone.
4. Follow the center / side / other side / tilt / center prompts.
5. Confirm Enrollment coverage shows at least 3 templates, ideally 5.
6. Save Face Setup.
7. You -> Test My Face Setup.
8. Test:
   - close frontal
   - glasses
   - side pose
   - group photo
   - distant photo
   - a DIFFERENT PERSON

Do not lower the threshold merely to make positives pass. Record the positive
and negative distributions. The commercial engine should create a clean
separation.

## Security / privacy boundaries

Before commercial release:
- no raw guided-enrollment video persisted;
- no biometric data in analytics or crash logs;
- explicit consent before enrollment;
- withdrawal/delete flow must delete biometric templates;
- event-scoped template distribution must be security-reviewed;
- enable Firebase App Check;
- rate-limit sensitive backend operations;
- independent privacy/security review;
- jurisdiction-specific biometric-law review.

The current consent screen is product plumbing, not legal advice or a final
privacy-policy substitute.
