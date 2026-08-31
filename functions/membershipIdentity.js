const { randomUUID } = require("crypto");
const { onDocumentCreated } = require("firebase-functions/v2/firestore");
const admin = require("firebase-admin");

const db = admin.firestore();

function normalizedMembershipId(value) {
  if (typeof value !== "string") return null;
  const id = value.trim();
  return id.length > 0 && id.length <= 128 ? id : null;
}

/**
 * Ensures opaque membership-generation IDs exist for the current
 * events/{eventId}/members/{userId} documents. The document paths intentionally
 * remain user-keyed for backward compatibility; membershipId distinguishes a
 * later leave/rejoin from the previous participation.
 *
 * The member document is the single authoritative copy. We deliberately avoid
 * duplicating this generation into participant/face or user event-reference
 * documents; trusted callers can join it with those records by userId. Less
 * duplication means fewer stale-identity and privacy/lifecycle failure modes.
 *
 * membershipId is a generation marker, never an authentication credential.
 * Authorization must still be based on Firebase Auth plus the current server
 * membership document.
 */
async function ensureMembershipIdentities(eventId, members) {
  const result = new Map();
  const missingUserIds = [];

  for (const member of members) {
    const userId = typeof member?.userId === "string" ? member.userId.trim() : "";
    if (!userId) continue;
    const known = normalizedMembershipId(member.data && member.data.membershipId);
    if (known) result.set(userId, known);
    else missingUserIds.push(userId);
  }

  if (missingUserIds.length === 0) return result;

  const generated = await db.runTransaction(async (tx) => {
    const refs = missingUserIds.map((userId) => db.doc(`events/${eventId}/members/${userId}`));
    const snaps = await Promise.all(refs.map((ref) => tx.get(ref)));
    const values = new Map();

    for (let index = 0; index < snaps.length; index += 1) {
      const snap = snaps[index];
      const userId = missingUserIds[index];

      // A leave/removal may race this migration. Never recreate membership
      // after the authoritative member document is gone.
      if (!snap.exists) continue;

      const current = normalizedMembershipId((snap.data() || {}).membershipId);
      if (current) {
        values.set(userId, current);
        continue;
      }

      const membershipId = randomUUID();
      tx.update(refs[index], { membershipId });
      values.set(userId, membershipId);
    }
    return values;
  });

  for (const [userId, membershipId] of generated) result.set(userId, membershipId);
  return result;
}

async function ensureMembershipIdentity(eventId, userId, knownMemberData = null) {
  const values = await ensureMembershipIdentities(eventId, [{ userId, data: knownMemberData || {} }]);
  return values.get(userId) || null;
}

exports.ensureMembershipIdentity = ensureMembershipIdentity;
exports.ensureMembershipIdentities = ensureMembershipIdentities;
exports.normalizedMembershipId = normalizedMembershipId;

// New memberships receive a random generation immediately after their trusted
// server transaction commits. Existing pre-migration memberships are lazily
// backfilled by trusted member-directory reads.
exports.assignMembershipIdentityOnCreate = onDocumentCreated(
  "events/{eventId}/members/{userId}",
  async (event) => {
    const { eventId, userId } = event.params;
    const data = event.data && event.data.data ? event.data.data() : null;
    await ensureMembershipIdentity(eventId, userId, data || null);
  }
);
