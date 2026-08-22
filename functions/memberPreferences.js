const { onCall, HttpsError } = require("firebase-functions/https");
const admin = require("firebase-admin");

const db = admin.firestore();
const Timestamp = admin.firestore.Timestamp;

function requireAuth(request) {
  if (!request.auth || !request.auth.uid) {
    throw new HttpsError("unauthenticated", "You must be signed in.");
  }
  return request.auth.uid;
}

function requireEventId(request) {
  const eventId = typeof request.data?.eventId === "string" ? request.data.eventId.trim() : "";
  if (!eventId) throw new HttpsError("invalid-argument", "Event is required.");
  return eventId;
}

async function requireMembership(eventId, uid) {
  const ref = db.doc(`events/${eventId}/members/${uid}`);
  const snap = await ref.get();
  if (!snap.exists) throw new HttpsError("permission-denied", "You are not a member of this Event.");
  return { ref, data: snap.data() || {} };
}

exports.getMemberPhotoPreferences = onCall(async (request) => {
  const uid = requireAuth(request);
  const eventId = requireEventId(request);
  const { data } = await requireMembership(eventId, uid);

  return {
    eventId,
    sharingEnabled: data.sharingEnabled !== false,
    includeOwnMatches: data.includeOwnMatches === true,
    sharingUpdatedAtMillis: data.sharingUpdatedAt?.toMillis ? data.sharingUpdatedAt.toMillis() : 0,
    ownMatchesUpdatedAtMillis: data.ownMatchesUpdatedAt?.toMillis ? data.ownMatchesUpdatedAt.toMillis() : 0,
  };
});

exports.setOwnPhotoVisibility = onCall(async (request) => {
  const uid = requireAuth(request);
  const eventId = requireEventId(request);
  const enabled = request.data?.enabled;
  if (typeof enabled !== "boolean") {
    throw new HttpsError("invalid-argument", "enabled must be true or false.");
  }

  const { ref } = await requireMembership(eventId, uid);
  await ref.update({ includeOwnMatches: enabled, ownMatchesUpdatedAt: Timestamp.now() });

  // Turning this off should hide existing photos sourced from this phone from
  // the owner's own Gallery while preserving appearances for other members.
  if (!enabled) {
    const sourceSnap = await db.collection(`events/${eventId}/photos`)
      .where("sourceUserId", "==", uid)
      .get();

    const batch = db.batch();
    let changed = 0;
    for (const doc of sourceSnap.docs) {
      const data = doc.data() || {};
      const matched = Array.isArray(data.matchedUserIds) ? data.matchedUserIds : [];
      if (!matched.includes(uid)) continue;
      const appearances = Array.isArray(data.appearances)
        ? data.appearances.filter((appearance) => appearance.participantUserId !== uid)
        : [];
      batch.update(doc.ref, {
        appearances,
        matchedUserIds: matched.filter((userId) => userId !== uid),
        updatedAt: Timestamp.now(),
      });
      changed += 1;
    }
    if (changed > 0) await batch.commit();
  }

  return { eventId, includeOwnMatches: enabled };
});
