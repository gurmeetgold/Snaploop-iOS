# SnapLoop Event Flow Patch

This patch turns the event/create/join/membership flow into a real Firebase flow.

## What changes

- Adds `FirebaseEventRepository`
- Adds FirebaseFunctions to the iOS target
- Makes `AppEnvironment.live()` use `FirebaseEventRepository`
- Keeps LIVE as the normal default (`SNAPLOOP_DEV=1` opts into stubs)
- Updates `EventMembershipService` for secure server-enforced joins
- Updates the Join screen so a non-member is not required to read the private roster
- Replaces Firestore rules with the server-coordinated event rules
- Adds callable Cloud Functions:
  - `createEvent`
  - `resolveInvite`
  - `joinEvent`
  - `leaveEvent`
- Adds the private server-maintained indexes:
  - `/joinCodes/{code}`
  - `/inviteTokens/{token}`
  - `/users/{uid}/eventRefs/{eventId}`

## Important

Cloud Functions deployment requires Firebase billing to be enabled (Blaze/pay-as-you-go).
Do not loosen the Firestore membership rules to avoid Functions.

This patch intentionally does NOT yet implement:
- real PhotoKit scanning
- real Vision face identity matching
- Firebase Storage thumbnails
- original-photo transfers
- Remote Config / Crashlytics / Analytics

Those belong to the next release slices after this one is built and tested.
