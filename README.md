# SnapLoop — iOS
[![FOSSA Status](https://app.fossa.com/api/projects/git%2Bgithub.com%2Fgurmeetgold%2FSnaploop-iOS.svg?type=shield)](https://app.fossa.com/projects/git%2Bgithub.com%2Fgurmeetgold%2FSnaploop-iOS?ref=badge_shield)


**Get every photo of you from everyone's camera — automatically.**

SnapLoop is an event-based group-photo collection utility for iPhone. During an
event, everyone uses their normal Camera app. Each phone periodically scans
**only its own** photo library, detects faces **on-device**, matches them
against the event's participants, and uploads only thumbnails + metadata for
matched photos. Every participant gets a personal feed of photos they appear in,
pulled from everyone's cameras — no manual uploading, no manual tagging.

This is **not** a social network: no friends list, no feed, no followers, no
messaging.

---

## Status — Phases 1–4 implemented (MVP feature-complete, pending Firebase/Vision concretes)

The full MVP surface is built: architecture, domain model, all pure
business-logic engines (extensively unit-tested), service protocol seams,
server-side Firestore rules + Cloud Functions, and the SwiftUI screens for the
whole loop. What remains is the **Phase 2-era `.live()` wiring**: the concrete
Firebase (Auth/Firestore/Storage/Remote Config/FCM/Analytics/Crashlytics) and
Vision + Core ML implementations behind the existing protocols — no engine
changes required.

| Phase | What landed |
|-------|-------------|
| **1 — Foundation** | FaceMatcher, ScanPlanner, EventLifecycle (pure), CameraSyncCoordinator, seams, config, human errors, app shell. |
| **2 — Events** | Create/edit (stable id/joinCode/inviteToken), InviteLink + DeepLinkRouter, membership service (join=consent, cap, leave revokes embedding), Firestore rules, Create/Join/Dashboard/Share UI. |
| **3 — Sync & delivery** | SyncProgress staged status, TransferJob state machine (idempotent), NotificationDebouncer, DownloadEstimator, Paginator, My Photos / Shared Album / Sync UI, Cloud Functions (invite resolve, batched notifications, idempotent transfers, rate limiting). |
| **4 — Trust & delight** | Erase/account-deletion cascade, expiry/grace messaging, RetryPolicy backoff, Analytics funnel + north-star (biometric-safe by type), Best-Shot/Blur/Highlights curation (flag-gated, additive), Entitlement scaffolding, retention/cleanup Cloud Functions, Privacy/Settings UI. |
| **Design pass** | Visual system (`Theme.swift`: coral/sky/violet gradient palette, gradient tiles, filter chips, insight banners) and a 5-tab shell (Home / Trips / Shared / Requests / You), restyled across every screen. See note below. |
| **Firebase wiring, step 1** | `AuthService` → real Firebase Auth (phone/OTP). See "Firebase live wiring" below for status and how to test it. |

### Design pass note

The visual design (colors, gradients, card layout, tab structure) was adapted
from a set of reference mockups for a similarly-named "SnapTrip" concept. Two
deliberate choices in translating them:

- **Naming/terminology kept as SnapLoop's**, since the product covers all event
  types (weddings, conferences, sports — not just trips); only the UI chrome
  ("Trips" tab label, "Trip Sync", etc.) borrows the mockups' wording where it
  reads naturally.
- **The mockups' "Nearby Transfer" (Bluetooth/Wi-Fi P2P) and "Cloud Pickup"
  concepts were not implemented literally** — they contradict this project's
  Phase 3 architecture rule that originals move only via a server-issued signed
  URL with a TTL, never device-to-device. The Requests screen adopts the same
  visual language (cards, icons, colors) but stays wired to the real
  `TransferJob` state machine (`Sources/Features/Transfers/RequestsView.swift`).

> **Not yet run.** This repo was authored in a Linux CI environment with no
> Swift/Xcode toolchain, so nothing here has been compiled or executed. The
> unit-test suites are written to pass on a Mac; the first `xcodebuild test`
> there is the real verification gate.

### Firebase live wiring

Every service the app depends on sits behind a protocol (`Sources/Services/Services.swift`).
`AppEnvironment.dev()` — the default — wires all of them to in-memory/local
stand-ins, so a fresh checkout builds and runs with **zero credentials**.
`AppEnvironment.live()` wires them to real backends, **one seam at a time**, in
an order chosen so each is independently testable before the next depends on
it:

| # | Seam | Status | Depends on |
|---|------|--------|------------|
| 1 | `AuthService` | ✅ **Live** — `FirebaseAuthService` (Firebase Auth, phone/OTP) | — |
| 2 | `UserDirectory`, `FaceProfileStore` | ⬜ Next | a signed-in user (step 1) |
| 3 | `EventRepository` | ⬜ Not started | a user profile (step 2) — this is the one that unlocks testing Create/Join Trip across two real devices |
| 4 | `MatchRepository`, `TransferRepository` | ⬜ Not started | events (step 3) — the core loop: My Photos / Shared Album, then downloads |
| 5 | `ConfigProviding` (Remote Config) | ⬜ Not started, low priority | none — can land anytime |
| — | `PhotoLibraryService`, `FaceDetectionService`, `QualityScoring` | ⬜ Stubbed, separate track | **Not Firebase.** Real PhotoKit + Vision/Core ML — its own chunk of work, independent of this list |

Toggle live services with **`SNAPLOOP_LIVE=1`** as an environment variable on
the Xcode scheme (Product ▸ Scheme ▸ Edit Scheme ▸ Run ▸ Arguments) — no code
edits needed. `AppEnvironment.current()` reads it and picks `.live()` or
`.dev()`; `SnapLoopApp` starts signed-out under `.live()` so you exercise the
real sign-in flow, and pre-signed-in under `.dev()` for fast iteration on
everything downstream of auth.

**Nothing reads or writes Firestore/Storage yet** — `FirebaseAuthService` only
touches Firebase Auth's own user record. `backend/firestore.rules` and
`backend/storage.rules` describe the schema steps 2–4 will implement against;
they're safe to paste into the console now (locking a schema down before any
writes happen is good practice), but treat them as prepared-ahead, not
currently exercised by any live code. `backend/storage.rules` also documents
one syntax point (Storage rules cross-referencing Firestore membership) that
couldn't be verified against current docs in this environment — see the
comment in that file for the fallback if the console rejects it. Step 4
(`TransferRepository`) will also require `firebase deploy --only functions`
for the transfer flow to do anything beyond sit at `queued` — it's designed to
call the `requestOriginalTransfer` Cloud Function, not write Firestore directly.

**When adding a Firebase product in a future step**, two rules, both learned
the hard way while wiring step 1:

1. **List it under `SnapLoop`'s `dependencies:` *and* mirror it onto
   `SnapLoopTests`'s.** Xcode's package-product linking isn't transitive
   across target dependencies in a generated project — `SnapLoopTests` needs
   its own explicit entry for every product `SnapLoop` needs, not just the
   ones its own test files happen to `import`, because `@testable import
   SnapLoop` links the whole module. Missing this caused a "Missing package
   product" error once already (`FirebaseCore` was on `SnapLoop` but not
   `SnapLoopTests`).
2. **Give the new product its own `packages:` alias pointing at the same
   `firebase-ios-sdk` URL**, rather than adding another `product:` line under
   the existing `FirebaseCore`/`FirebaseAuthPkg` blocks. Confirmed via raw
   `xcodebuild` dependency-graph output (xcodegen 2.46.0): declaring two
   products from *one* package block, where one transitively depends on the
   other (as `FirebaseAuth` depends on `FirebaseCore`), causes XcodeGen to
   silently drop the "redundant-looking" one from the target's explicit
   package-product dependencies — even though the Swift compiler needs an
   explicit entry to `import` a module regardless of what else you link
   already depends on it internally. Aliasing each product under its own
   top-level package name in `packages:` sidesteps whatever same-package
   dedup logic causes this; SPM is fine resolving one remote URL under
   multiple local names. See the comment block above `packages:` in
   `project.yml` for the full writeup. Worth retrying the simpler one-package
   form after an XcodeGen upgrade, in case a later release fixes the collapse.

#### Testing step 1 (Auth) today

1. Create a Firebase project (console.firebase.google.com), add an iOS app with
   bundle id `com.snaploop.app`, enable **Phone** sign-in under Authentication.
2. Download its `GoogleService-Info.plist` and drag it into the `SnapLoop`
   group in Xcode after `xcodegen generate` (it's gitignored — never commit a
   real one).
3. Real SMS won't reach a Simulator: add a **test phone number + fixed code**
   under Authentication ▸ Sign-in method ▸ Phone ▸ Phone numbers for testing.
4. Set `SNAPLOOP_LIVE=1` on the scheme, run, and sign in with the test number.
5. `session.user` is set from the Firebase Auth UID alone — no Firestore
   profile is created or read yet (that's step 2), so `displayName` is nil and
   `hasFaceProfile` is false regardless of prior state.

One thing to verify on your own SDK version: `FirebaseAuthService.mapError`
switches over a specific set of `AuthErrorCode` cases (`invalidPhoneNumber`,
`missingPhoneNumber`, `invalidVerificationCode`, `missingVerificationCode`,
`sessionExpired`, `invalidVerificationID`, `missingVerificationID`,
`networkError`, `tooManyRequests`). These are long-stable, commonly-used cases,
but I couldn't cross-check them against the SDK docs in this environment — if
any has been renamed in the `firebase-ios-sdk` version Swift Package Manager
resolves, Xcode will flag the exact line immediately (it's a simple enum-case
typo, trivial to fix).

### What's built

| Area | File(s) | Notes |
|------|---------|-------|
| Config (all tunables) | `Sources/Core/RemoteConfigValues.swift` | Threshold, margin, grace, TTL, thumbnail size, limits — nothing hardcoded at call sites. |
| Typed errors + human copy | `Sources/Core/AppError.swift` | The only place UI error strings live; no technical internals leak. |
| Injectable clock | `Sources/Core/Clock.swift` | Deterministic time in tests. |
| Domain models | `Sources/Models/*` | `User`, `FaceProfile`, `Event`, `EventParticipant`, `FaceEmbedding`, `DetectedFace`, `PhotoAsset`, `PhotoMatch`, `ScanState`. |
| **FaceMatcher** (pure) | `Sources/Features/Matching/FaceMatcher.swift` | Precision-favoring: confidence threshold **+** ambiguity margin. |
| **ScanPlanner** (pure) | `Sources/Features/PhotoScanner/ScanPlanner.swift` | Incremental, date-range filtered, never rescans, batched. |
| **EventLifecycle** (pure) | `Sources/Features/Events/EventLifecycle.swift` | active/grace/expired + sync/download gates + date validation. |
| Sync orchestrator | `Sources/Features/PhotoScanner/CameraSyncCoordinator.swift` | Composes the engines with device services for one on-demand pass. |
| Service seams | `Sources/Services/Services.swift` | Auth, PhotoLibrary, FaceDetection, EventRepository, MatchRepository, ConfigProviding, ScanStateStore. |
| Local/real impls | `Sources/Services/LocalImplementations.swift`, `Sources/Features/Transfers/ImageIOThumbnailEncoder.swift` | `UserDefaults` scan-state store; ImageIO thumbnail encoder. |
| App shell | `Sources/App/*`, `Sources/Features/Home/HomeView.swift` | DI container + SwiftUI skeleton. |

### Architectural rules this phase enforces

- **A device only ever touches its own library.** The planner/coordinator have
  no concept of another user's assets, by construction.
- **Matching is on-device and pure.** `FaceMatcher` operates on `FaceEmbedding`
  value types — no cloud vision, no per-photo LLM call. Favors **precision over
  recall**; every match is correctable via "Not Me" (`dismissAppearance`).
- **On-demand sync, incremental.** No 24/7 background scanning. `ScanState`
  guarantees an asset is never rescanned.
- **Thumbnails + metadata only.** Originals move on demand via a signed URL with
  a config TTL (default 48h) — never bulk-uploaded.
- **Stable event identity.** `Event.id` and `Event.joinCode` are immutable;
  editing name/dates/cover never touches them (`updateEventDetails` can't).
- **Everything configurable is remote-config-driven** with safe shipped defaults.
- **No technical internals in UI copy** — see `AppError.userMessage`.

---

## Building & testing (requires a Mac with Xcode)

> This repo was scaffolded in a Linux CI environment with **no Swift/Xcode
> toolchain**, so the build and test suite have **not** been executed here.
> They are written to compile and pass on a Mac; run them there:

```bash
# 1. Generate the Xcode project from project.yml
brew install xcodegen        # once
xcodegen generate            # produces SnapLoop.xcodeproj (git-ignored)

# 2. Build + run tests
xcodebuild test \
  -project SnapLoop.xcodeproj \
  -scheme SnapLoop \
  -destination 'platform=iOS Simulator,name=iPhone 15'
```

The app runs today on `AppEnvironment.dev()` — in-memory services, **no Firebase,
no credentials**. It renders the Home skeleton and empty states.

---

## Project layout

```
Sources/
  App/         DI container (AppEnvironment) + SwiftUI entry + RootView
  Core/        RemoteConfigValues, AppError, Clock, Log
  Models/      pure domain value types
  Services/    protocol seams + local/in-memory implementations + dev stubs
  Features/
    Matching/       FaceMatcher (pure)
    PhotoScanner/   ScanPlanner (pure) + CameraSyncCoordinator
    Events/         EventLifecycle (pure) + JoinCode
    Transfers/      ImageIOThumbnailEncoder
    Home/           HomeView skeleton
    …               Authentication, Onboarding, FaceProfile, MyPhotos,
                    SharedAlbum, Settings (built out in later phases)
Tests/SnapLoopTests/   FaceMatcher, ScanPlanner, EventLifecycle,
                       FaceEmbedding, JoinCode, CameraSyncCoordinator
```

## What's next

See **"Firebase live wiring"** above for the current seam-by-seam status and
how to test what's live today. Short version: `AuthService` is real (Firebase
Auth, phone/OTP); `UserDirectory`/`FaceProfileStore` are next, then
`EventRepository`, then `MatchRepository`/`TransferRepository`, then Remote
Config — each step lands independently testable before the next depends on it.
The on-device PhotoKit + Vision/Core ML implementations (`PhotoLibraryService`,
`FaceDetectionService`, `QualityScoring`) are a separate track, unrelated to
Firebase. No engine changes are required for any of this — that's the point of
the seams.


## License
[![FOSSA Status](https://app.fossa.com/api/projects/git%2Bgithub.com%2Fgurmeetgold%2FSnaploop-iOS.svg?type=large)](https://app.fossa.com/projects/git%2Bgithub.com%2Fgurmeetgold%2FSnaploop-iOS?ref=badge_large)