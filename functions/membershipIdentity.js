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
 * Ensures one opaque membership-generation ID exists for the current
 * events/{eventId}/members/{userId} document. The document path intentionally
 * remains user-keyed for backward compatibility; membershipId distinguishes a
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
async function ensureMembershipIdentity(eventId, userId, knownMemberData = null) {
  const known = normalizedMembershipId(knownMemberData && knownMemberData.membershipId);
  if (known) return known;

  const memberRef = db.doc(`events/${eventId}/members/${userId}`);
  return db.runTransaction(async (tx) => {
    const memberSnap = await tx.get(memberRef);

    // A leave/removal may race this migration/trigger. Never recreate membership
    // after the authoritative member document is gone.
    if (!memberSnap.exists) return null;

    const current = normalizedMembershipId((memberSnap.data() || {}).membershipId);
    if (current) return current;

    const membershipId = randomUUID();
    tx.update(memberRef, { membershipId });
    return membershipId;
  });
}

exports.ensureMembershipIdentity = ensureMembershipIdentity;
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
