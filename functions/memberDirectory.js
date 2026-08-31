const { onCall, HttpsError } = require("firebase-functions/https");
const admin = require("firebase-admin");
const membershipIdentity = require("./membershipIdentity");

const db = admin.firestore();

function requireAuth(request) {
  if (!request.auth || !request.auth.uid) {
    throw new HttpsError("unauthenticated", "You must be signed in.");
  }
  return request.auth.uid;
}

exports.listEventMembers = onCall(async (request) => {
  const uid = requireAuth(request);
  const eventId = typeof request.data?.eventId === "string" ? request.data.eventId.trim() : "";
  if (!eventId) throw new HttpsError("invalid-argument", "Event is required.");

  const callerMemberRef = db.doc(`events/${eventId}/members/${uid}`);
  const callerMemberSnap = await callerMemberRef.get();
  if (!callerMemberSnap.exists) {
    throw new HttpsError("permission-denied", "You are not a member of this Event.");
  }

  const membersSnap = await db.collection(`events/${eventId}/members`).orderBy("joinedAt", "asc").get();
  const userRefs = membersSnap.docs.map((doc) => db.doc(`users/${doc.id}`));
  const userSnaps = userRefs.length > 0 ? await db.getAll(...userRefs) : [];
  const namesById = new Map();
  userSnaps.forEach((snap) => {
    if (!snap.exists) return;
    const user = snap.data() || {};
    const name = typeof user.displayName === "string" ? user.displayName.trim() : "";
    if (name) namesById.set(snap.id, name);
  });

  // Pre-migration memberships may not have a generation ID yet. Backfill them
  // through a transaction that refuses to recreate a concurrently removed
  // membership. New memberships normally already have this field via the
  // on-create trigger in membershipIdentity.js.
  const membershipIds = await Promise.all(membersSnap.docs.map((doc) =>
    membershipIdentity.ensureMembershipIdentity(eventId, doc.id, doc.data() || {})
  ));

  return {
    members: membersSnap.docs.map((doc, index) => {
      const data = doc.data() || {};
      return {
        userId: doc.id,
        membershipId: membershipIds[index] || null,
        displayName: namesById.get(doc.id) || null,
        role: data.role || "participant",
        sharingEnabled: data.sharingEnabled !== false,
        joinedAtMillis: data.joinedAt?.toMillis ? data.joinedAt.toMillis() : null,
        lastSyncAtMillis: data.lastSyncAt?.toMillis ? data.lastSyncAt.toMillis() : null,
        faceTemplateVersion: Number(data.faceTemplateVersion || 1),
      };
    }),
  };
});
