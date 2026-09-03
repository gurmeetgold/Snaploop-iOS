import fs from "node:fs";
import path from "node:path";
import { test } from "node:test";
import assert from "node:assert/strict";

const expectedExports = new Set([
  "acceptBiometricConsent",
  "assignMembershipIdentityOnCreate",
  "cleanupRemovedMemberPhotoData",
  "createEvent",
  "declineEventInvite",
  "deleteMyAccount",
  "deliverNotificationRecord",
  "disableOwnMatchesEverywhere",
  "dismissAppearance",
  "ensureMyFaceIdentity",
  "eraseMyFaceProfile",
  "expirePendingInvites",
  "getMatchedThumbnail",
  "getMemberPhotoPreferences",
  "hardDeleteDeletedTrips",
  "hydrateDeferredInvites",
  "inviteByPhone",
  "invitePreview",
  "joinEvent",
  "leaveEvent",
  "listEventFaceProfiles",
  "listEventInvites",
  "listEventMembers",
  "listMyMatchedPhotos",
  "manageEventMember",
  "markInviteJoined",
  "nextPendingInvite",
  "notifyPendingInvite",
  "publishMatch",
  "purgeDeletedTripPreviews",
  "purgeExpiredBiometricProfiles",
  "purgeExpiredTripPreviews",
  "refreshMyFaceProfile",
  "registerPushToken",
  "resolveInvite",
  "resolveInvitePreview",
  "revokeEventInvite",
  "saveMyFaceProfile",
  "scrubLegacyParticipantBiometrics",
  "scrubMatchesOnFaceProfileChange",
  "scrubParticipantBiometrics",
  "setEventStatus",
  "setOwnPhotoVisibility",
  "setSharing",
  "syncEventRosterIdentities",
  "syncMyUserProfile",
  "unregisterPushToken",
  "updateDisplayName",
  "updateEventManaged",
  "withdrawBiometricConsent",
]);

function bootstrapExports() {
  const source = fs.readFileSync("functions/bootstrap.js", "utf8");
  return new Set([...source.matchAll(/exports\.([A-Za-z0-9_]+)\s*=/g)].map((match) => match[1]));
}

function swiftCallableNames(root) {
  const names = new Set();
  const stack = [root];
  while (stack.length) {
    const current = stack.pop();
    for (const entry of fs.readdirSync(current, { withFileTypes: true })) {
      const full = path.join(current, entry.name);
      if (entry.isDirectory()) {
        stack.push(full);
        continue;
      }
      if (!entry.name.endsWith(".swift")) continue;
      const source = fs.readFileSync(full, "utf8");
      for (const match of source.matchAll(/httpsCallable\(\s*"([^"]+)"\s*\)/g)) names.add(match[1]);
      for (const match of source.matchAll(/\bcall\(\s*"([^"]+)"\s*,\s*data:/g)) names.add(match[1]);
    }
  }
  return names;
}

test("production bootstrap exposes only the reviewed callable and trigger surface", () => {
  const actual = bootstrapExports();
  assert.deepEqual([...actual].sort(), [...expectedExports].sort());
});

test("every literal callable used by the iOS source is exported by production bootstrap", () => {
  const exported = bootstrapExports();
  const used = swiftCallableNames("Sources");
  const missing = [...used].filter((name) => !exported.has(name));
  assert.deepEqual(missing, [], `Missing callable exports: ${missing.join(", ")}`);
});

test("release device testing deploys the complete matching backend and security rules", () => {
  const script = fs.readFileSync("scripts/prepare_release_device_test.sh", "utf8");
  assert.match(
    script,
    /firebase deploy --project getsnaploop --only functions,firestore:rules,storage/,
    "Release device tests must deploy all Functions plus Firestore/Storage rules so the iOS Change 4 contract cannot run against a stale partial backend."
  );
  assert.doesNotMatch(
    script,
    /functions:publishMatch|functions:listEventFaceProfiles|functions:listMyMatchedPhotos/,
    "Do not return to a hand-maintained matching-function allowlist; deploy the complete Functions surface for a Release device test."
  );
});
