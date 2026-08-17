# SnapLoop next UX patch

This patch adds:

- real participant display names instead of Firebase UIDs
- "Add/Edit Your Name" in the You tab
- secure `updateDisplayName` Cloud Function that also updates existing event rosters
- visible Cancel button on the Join Trip screen
- direct "Add Your Name" and "Set Up Your Face" actions inside Join Trip
- automatic return to the invite after face/name setup
- Invite People available to every trip member, not just the organizer
- Share Invite using the iOS system share sheet
- Copy Code
- Copy Link
- QR code
- front-camera "Take Selfie" on a real iPhone
- photo-library selfie selection for Simulator/testing
- participant avatars based on names instead of Firebase IDs

## Install

From the SnapLoop repo root:

```bash
cd /Users/gurmeet/Documents/GC-Workspace/GC-SnapLoop/Snaploop-iOS
```

Unzip this patch over the repo root, preserving directories.

Then deploy the updated backend:

```bash
firebase deploy --only functions
```

Regenerate the Xcode project:

```bash
xcodegen generate
```

Build:

```bash
xcodebuild \
  -project SnapLoop.xcodeproj \
  -scheme SnapLoop \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  build
```

## Test

For EACH of the two existing users:

1. Open You.
2. Tap Add Your Name / Edit Your Name.
3. Save a name.
4. Return to the trip and refresh Participants.

The backend updates both `users/{uid}.displayName` and the existing
`events/{eventId}/participants/{uid}.displayName` snapshot.

Then test Invite People from the trip dashboard:

- Share Invite
- Copy Code
- Copy Link
- QR

The iOS share sheet offers installed apps that accept the shared text, such as
Messages, WhatsApp and other compatible share extensions. Individual apps decide
whether/how they appear in the share sheet.

## Selfie testing

On a real iPhone, Face Setup now has Take Selfie using the front camera.

The iOS Simulator has no camera. Its photo picker only shows images that exist
inside the Simulator's Photos library. If you only see landscapes, add a selfie
to the Simulator Photos library and choose it with Choose Photo.

IMPORTANT: the current FaceDetectionService is still a stub. This patch improves
the setup UX/persistence but does not turn the stub into production face
recognition. The real on-device face pipeline remains the next major engineering
slice.
