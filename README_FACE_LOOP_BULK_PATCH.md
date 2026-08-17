# SnapLoop Face Loop Bulk Patch

This patch is deliberately large. It closes the development/testing gap between
"Firebase/event plumbing works" and "I can exercise the complete photo loop on
a real iPhone".

## What it adds

### Face Setup v2
- Old version-1 stub descriptors are rejected automatically.
- Users are prompted to redo Face Setup once.
- Take & Crop Selfie uses the iOS editor for zoom/crop.
- Choose & Crop Photo also uses the iOS editor.
- If a chosen photo still contains multiple faces, SnapLoop detects the faces
  and asks the user to tap their own face.
- The selected reference crop is saved ONLY on the device so Update Face Setup
  can display the old/current reference image.
- Saving a new face descriptor refreshes that user's face descriptor in all
  existing event participant rosters; no leave/rejoin required.

### Full-loop development matching
DEBUG builds now use:
1. Vision face detection
2. tight face crop
3. Vision image feature print on the face crop
4. existing SnapLoop precision/ambiguity matcher

This is a REAL on-device descriptor and is useful for validating PhotoKit ->
matching -> thumbnail upload -> Firestore -> My Photos -> Shared Album.

BUT it is not the release face-recognition model. Apple's feature-print API is
an image-similarity primitive, not an identity-trained face model. Release
builds still refuse to scan until the dedicated Core ML identity model is
installed.

This is intentional: it lets us test the complete architecture now without
silently shipping an unvalidated biometric matcher.

### Matching verification screen
You -> Test My Face Setup
- choose any gallery photo containing you
- group photo is fine
- SnapLoop scans every face
- shows number of faces, best similarity, threshold, and pass/fail

Use this to gather real scores before we tune thresholds or install the release
model.

### Critical same-iPhone/two-user fix
Scan state is now scoped by:
- event
- signed-in user
- face-model version

So user A scanning on an iPhone will NOT cause user B on the same iPhone to
skip those assets. A future face-model upgrade automatically re-scans photos.

### Invite landing page
Development invite links now use:
https://snaploop-dev.web.app/e/<token>

The Firebase Hosting page:
- has an Open SnapLoop button using `snaploop://...`
- will expose an App Store download button once the real App Store URL is known

The QR uses the same HTTPS link.

True one-tap Universal Links require the production Associated Domains setup;
we do that during the paid Apple Developer/App Store hardening phase.

## Install

Unzip this archive over the SnapLoop repo root.

Then:

```bash
cd /Users/gurmeet/Documents/GC-Workspace/GC-SnapLoop/Snaploop-iOS

cd functions
npm install
cd ..

firebase deploy --only functions,hosting

rm -rf SnapLoop.xcodeproj
xcodegen generate

rm -rf ~/Library/Developer/Xcode/DerivedData/SnapLoop-*

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

## Required test order

Both existing users currently have old version-1 stub descriptors.

For EACH user:
1. Sign in.
2. You -> Face Setup.
3. Choose/take a photo and save it again.
4. Confirm You now shows "Test My Face Setup".
5. Test My Face Setup with a DIFFERENT photo that contains that person.

Only after BOTH participants have v2 Face Setup:

### Source-user scan
1. Sign in as user 1.
2. Open the trip.
3. Sync My Camera.
4. Grant Full Photos access if requested.
5. Let the pass finish.
6. Open Shared Album and My Photos.

If user 1's gallery contains a trip-date photo of user 2 and the descriptor
passes the conservative threshold, the match is uploaded and user 2 can see it
after signing in and refreshing.

## Important testing interpretation

- No Storage files before matching is expected.
- Face Setup itself does NOT add that photo to Shared Album.
- Shared Album contains trip-date photos found by Sync My Camera.
- A photo only uploads when at least one event participant is confidently
  matched.
- Same phone / two accounts is now supported for development testing, but final
  multi-device validation still needs two real phones.

## Still after this patch

1. Replace DEBUG Vision feature print with identity-trained Core ML embedder.
2. Calibrate thresholds using positive/negative real photo sets.
3. Original-photo request/upload/download lifecycle.
4. Push notifications.
5. Admin role.
6. Phone-auth country selector / E.164 normalization and APNs verification work.
7. Production Universal Links + App Store fallback.
8. App Check / Crashlytics / account deletion / App Store hardening.
