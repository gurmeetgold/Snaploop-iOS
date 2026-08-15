# SnapLoop — iOS

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

> **Not yet run.** This repo was authored in a Linux CI environment with no
> Swift/Xcode toolchain, so nothing here has been compiled or executed. The
> ~15 unit-test suites are written to pass on a Mac; the first `xcodebuild test`
> there is the real verification gate.

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

## What's next (Phase 2)

Firebase wiring (`AppEnvironment.live()`): Auth (phone OTP), Firestore
(`EventRepository`/`MatchRepository`), Storage (thumbnails + signed originals),
Remote Config (`ConfigProviding`), FCM, Analytics/Crashlytics — plus the real
Vision + Core ML `FaceDetectionService`, and the Authentication / Onboarding /
FaceProfile UI flows. No engine changes required — that's the point of the seams.
