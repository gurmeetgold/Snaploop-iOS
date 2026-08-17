# SnapLoop bulk core-plumbing patch

This patch assumes the previous Auth/Event/UX patches are already installed.

## What this patch adds

1. Participant identity fallback
   - display name first
   - phone number when display name is missing
   - Firebase UID is no longer shown as normal roster copy
   - existing event rosters are backfilled by `syncEventRosterIdentities`

2. Real PhotoKit library service
   - real iOS Photos permission
   - event-date-range asset discovery
   - image loading/downsampling
   - originals remain local

3. Real Firebase match persistence
   - matched thumbnails -> Firebase Storage
   - match metadata -> Firestore
   - My Photos query
   - Shared Album query
   - Not Me -> trusted callable function

4. Real thumbnail loading
   - My Photos and Shared Album fetch Storage thumbnails
   - small in-memory image cache

5. Real Firebase Remote Config provider
   - shipped defaults always work
   - Firebase values can override them later

6. Backend hardening
   - Node.js 22 runtime
   - secure roster identity refresh
   - secure Not Me update
   - tightened Firestore photo rules
   - verified cross-service Storage membership rules

7. Safety guard around unfinished face recognition
   - the real camera library is NOT marked scanned while the identity model is
     still a stub
   - Sync My Camera returns a clear message instead of consuming photos

## Important: what is still NOT finished

The production face identity/embedding model is still the largest core blocker.
PhotoKit + Storage + Firestore are now ready for it, but this patch deliberately
prevents the stub FaceDetectionService from scanning the real library.

Original full-resolution transfer is also still a later slice. Thumbnails and
match feeds are live; originals still remain device-local.

## Install

From the repo root, unzip the patch over the existing project, preserving paths.

Then:

```bash
cd /Users/gurmeet/Documents/GC-Workspace/GC-SnapLoop/Snaploop-iOS
```

### 1. Enable Firebase Storage once

If Firebase Console -> Build -> Storage has never been initialized, click
"Get started" and create the default bucket first.

### 2. Install function dependencies / Node 22 lockfile

```bash
cd functions
npm install
cd ..
```

### 3. Deploy backend + rules

```bash
firebase deploy --only functions,firestore:rules,storage
```

### 4. Regenerate Xcode project

```bash
rm -rf SnapLoop.xcodeproj
xcodegen generate
```

### 5. Resolve Firebase packages

```bash
xcodebuild \
  -resolvePackageDependencies \
  -project SnapLoop.xcodeproj \
  -scheme SnapLoop
```

The project now uses Firebase Apple SDK 12.17.0+ and adds:
- FirebaseStorage
- FirebaseRemoteConfig

### 6. Clean build

```bash
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

## Test after build

1. Open the existing trip.
2. Open Participants.
3. For any user with no display name, their phone number should appear instead
   of Firebase UID.
4. A user with a display name should show the display name.
5. Open Sync My Camera.
   - while the production face model is still missing, SnapLoop should explain
     that matching is not ready for this build.
   - it should NOT mark the camera roll scanned.
6. On a real iPhone, after the face model slice lands, PhotoKit will request
   access and scan only photos inside the trip date range.

## Remote Config

You do not need to configure Firebase Remote Config immediately. The app ships
safe defaults. Later, matching thresholds, batch size, thumbnail quality, event
limits, and feature flags can be overridden in Firebase Console without an app
update.
