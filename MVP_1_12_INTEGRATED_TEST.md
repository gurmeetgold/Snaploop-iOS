# MyPicsRoom MVP 1–12 integrated test

Branch: `chatgpt/mvp-bulk-1-12`

This build keeps Face Model **v5 / AuraFace** but moves camera scanning to scan generation **face-v5.1**, so old v5.0 scan state will not suppress the new recognition pass.

## Before testing

1. Keep `Sources/Resources/Models/SnapLoopFaceEmbedding.mlmodel` installed locally.
2. Regenerate the Xcode project after pulling this branch.
3. Build with `FIREBASE_SOURCE_FIRESTORE=1`.
4. Deploy the new callable functions before testing phone/contact invitations.
5. Re-run Guided Selfie Scan for Account A and Account B. The neural embedding space is still v5, but guided enrollment now sends the original camera frame through the canonical five-point alignment once instead of loose-crop → realign.

## Face Setup

- Guided Selfie Scan is the recommended MVP path.
- Update Face Setup should show the UID-scoped local reference image when this device has one.
- One optional gallery image can be edited/cropped/zoomed with the system picker.
- If the edited image contains multiple faces, choose the correct face.
- Test My Face Setup should remain available after a valid v5 profile is saved.

## Face Test / benchmark

For each account, test both `This is me` and `This is NOT me`.

Record:
- Vision faces
- usable landmarks
- alignment failures
- aligned crop shown under “What AuraFace received”
- eye distance / size / quality / yaw / pitch / roll
- best score
- second template score
- decision reason

Do not change the 0.520 evaluation threshold from genuine samples alone.

## Shared-device account isolation

Using the same iPhone:

1. Sign in as Account A and confirm A's reference image/profile.
2. Sign out.
3. Sign in as Account B and confirm A's preview does not remain.
4. Sign out and return to A; confirm B's preview/profile does not appear.
5. Camera scan state is keyed by event + UID + `face-v5.1`.

## End-to-end trip

1. Account A creates a trip that covers the dates of your test photos.
2. Account B joins.
3. Confirm the event participant roster has current v5 profiles.
4. Put Person A-only, Person B-only, both-people, difficult, and wrong-person photos in the device library.
5. Run Sync My Camera.
6. Confirm A-only photos appear for A, B-only for B, both-person photos for both, and wrong-person photos do not leak into My Photos.
7. Confirm Shared Album and Not Me still work.

The v5.1 scanner requests a 2048px working image so more distant faces reach Vision. Cloud thumbnail dimensions remain unchanged.

## Phone auth

- Country defaults from the iPhone region.
- Change country manually and verify the calling code changes.
- Paste a full `+countrycode...` number and verify it is preserved as E.164.
- On physical iPhone, watch whether Firebase silent APNs verification avoids the human-verification page. reCAPTCHA remains a legitimate Firebase fallback and is not bypassed.

## Organizer phone/contact invitation

The new callable functions must be deployed first.

- Organizer → Invite → Add by Phone or Contacts.
- Existing MyPicsRoom account: server returns `in_app`; no SMS composer should open.
- Recipient: open/foreground MyPicsRoom; pending trip invitation should appear. Accept or Decline.
- Non-existing phone number: server returns `sms`; prepared Messages composer should open with the stable HTTPS trip link.
- Organizer invite screen shows Invited / Joined / Declined / Expired status as applicable.
- Nobody is silently auto-joined.

## Invite links

Current development URL: `https://snaploop-dev.web.app/e/<token>`.

- Installed app: landing page's Open MyPicsRoom button uses `snaploop://e/<token>` and routes to the exact trip.
- SwiftUI also handles HTTPS browsing user activities in preparation for Universal Links.
- True one-tap Universal Links and install→resume require the production Apple Associated Domains/AASA setup and final App Store listing. Do not treat those external release prerequisites as completed by this development build.

## Commercial note

AuraFace remains an evaluation model in this branch. The benchmark, model provenance/licensing review, biometric/privacy/security review, and production operating threshold are still release gates.
