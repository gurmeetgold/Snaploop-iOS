import { createRequire } from "node:module";
import test from "node:test";
import assert from "node:assert/strict";

const require = createRequire(import.meta.url);
const {
  dismissRecipientMatchMetadata,
  finalizeIncrementalMatchState,
  normalizedDismissedUserIds,
  prepareIncrementalMatchState,
  recipientDismissalApplies,
  removeRecipientMatchMetadata,
  upsertActiveAppearance,
} = require("../../functions/change4MatchMetadata.js");

function activePhoto() {
  return {
    appearances: [{
      participantUserId: "member",
      confidence: 0.91,
      faceIdentityId: "face-1",
      faceProfileRevision: "revision-1",
      recipientMembershipId: "membership-1",
      dismissedByUser: false,
    }],
    matchedUserIds: ["member"],
    matchedFaceIdentityIds: { member: "face-1" },
    matchedProfileRevisions: { member: "revision-1" },
    matchedMembershipIds: { member: "membership-1" },
  };
}

test("Not Me removes every active authorization and records a generation-bound tombstone", () => {
  const result = dismissRecipientMatchMetadata(activePhoto(), "member", "membership-1");

  assert.deepEqual(result.appearances, []);
  assert.deepEqual(result.matchedUserIds, []);
  assert.deepEqual(result.matchedFaceIdentityIds, {});
  assert.deepEqual(result.matchedProfileRevisions, {});
  assert.deepEqual(result.matchedMembershipIds, {});
  assert.deepEqual(result.dismissedUserIds, ["member"]);
  assert.deepEqual(result.dismissedMembershipIds, { member: "membership-1" });
});

test("incremental publication cannot resurrect a dismissal in the same membership generation", () => {
  const dismissed = dismissRecipientMatchMetadata(activePhoto(), "member", "membership-1");
  const state = prepareIncrementalMatchState(dismissed);

  assert.equal(recipientDismissalApplies(state, "member", "membership-1"), true);
  assert.equal(upsertActiveAppearance(state, {
    participantUserId: "member",
    confidence: 0.99,
    faceIdentityId: "face-1",
    faceProfileRevision: "revision-2",
    recipientMembershipId: "membership-1",
  }), false);

  const result = finalizeIncrementalMatchState(state);
  assert.deepEqual(result.matchedUserIds, []);
  assert.deepEqual(result.dismissedUserIds, ["member"]);
});

test("leave and rejoin clears only the old generation dismissal and permits a fresh match", () => {
  const dismissed = dismissRecipientMatchMetadata(activePhoto(), "member", "membership-1");
  const state = prepareIncrementalMatchState(dismissed);

  assert.equal(recipientDismissalApplies(state, "member", "membership-2"), false);
  assert.equal(upsertActiveAppearance(state, {
    participantUserId: "member",
    confidence: 0.94,
    faceIdentityId: "face-1",
    faceProfileRevision: "revision-1",
    recipientMembershipId: "membership-2",
  }), true);

  const result = finalizeIncrementalMatchState(state);
  assert.deepEqual(result.dismissedUserIds, []);
  assert.deepEqual(result.dismissedMembershipIds, {});
  assert.deepEqual(result.matchedUserIds, ["member"]);
  assert.equal(result.matchedMembershipIds.member, "membership-2");
});

test("legacy dismissed appearance migrates to an unbound fail-closed tombstone", () => {
  const legacy = {
    appearances: [{
      participantUserId: "member",
      confidence: 0.8,
      dismissedByUser: true,
    }],
    matchedUserIds: [],
  };

  assert.deepEqual([...normalizedDismissedUserIds(legacy)], ["member"]);
  const state = prepareIncrementalMatchState(legacy);
  assert.equal(recipientDismissalApplies(state, "member", "membership-new"), true);
  assert.equal(state.appearanceByUser.has("member"), false);
});

test("finalization prunes orphaned identity, revision and membership maps", () => {
  const state = prepareIncrementalMatchState({
    appearances: [{
      participantUserId: "active",
      confidence: 0.9,
      faceIdentityId: "active-face",
      faceProfileRevision: "active-revision",
      recipientMembershipId: "active-membership",
      dismissedByUser: false,
    }],
    matchedFaceIdentityIds: { active: "active-face", stale: "stale-face" },
    matchedProfileRevisions: { active: "active-revision", stale: "stale-revision" },
    matchedMembershipIds: { active: "active-membership", stale: "stale-membership" },
    dismissedUserIds: ["dismissed"],
    dismissedMembershipIds: { dismissed: "dismissed-membership", orphan: "orphan-membership" },
  });

  const result = finalizeIncrementalMatchState(state);
  assert.deepEqual(result.matchedUserIds, ["active"]);
  assert.deepEqual(result.matchedFaceIdentityIds, { active: "active-face" });
  assert.deepEqual(result.matchedProfileRevisions, { active: "active-revision" });
  assert.deepEqual(result.matchedMembershipIds, { active: "active-membership" });
  assert.deepEqual(result.dismissedUserIds, ["dismissed"]);
  assert.deepEqual(result.dismissedMembershipIds, { dismissed: "dismissed-membership" });
});

test("membership cleanup can remove active and dismissal metadata completely", () => {
  const dismissed = dismissRecipientMatchMetadata(activePhoto(), "member", "membership-1");
  const result = removeRecipientMatchMetadata(dismissed, "member", { removeDismissal: true });

  assert.deepEqual(result.appearances, []);
  assert.deepEqual(result.matchedUserIds, []);
  assert.deepEqual(result.matchedFaceIdentityIds, {});
  assert.deepEqual(result.matchedProfileRevisions, {});
  assert.deepEqual(result.matchedMembershipIds, {});
  assert.deepEqual(result.dismissedUserIds, []);
  assert.deepEqual(result.dismissedMembershipIds, {});
});
