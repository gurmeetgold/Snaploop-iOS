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

function requireString(value, name) {
  if (typeof value !== "string" || !value.trim()) {
    throw new HttpsError("invalid-argument", `${name} is required.`);
  }
  return value.trim();
}

function toMillis(value) {
  return value instanceof Timestamp ? value.toMillis() : null;
}

exports.listMyMatchedPhotos = onCall(async (request) => {
  const uid = requireAuth(request);
  const eventId = requireString((request.data || {}).eventId, "eventId");

  const memberSnap = await db.doc(`events/${eventId}/members/${uid}`).get();
  if (!memberSnap.exists) {
    throw new HttpsError("permission-denied", "Join this event first.");
  }

  const snap = await db.collection(`events/${eventId}/photos`)
    .where("matchedUserIds", "array-contains", uid)
    .get();

  const photos = snap.docs.map((doc) => {
    const data = doc.data() || {};
    return {
      id: data.id || "",
      eventId: data.eventId || eventId,
      sourceUserId: data.sourceUserId || "",
      assetLocalId: data.assetLocalId || "",
      appearances: Array.isArray(data.appearances) ? data.appearances : [],
      capturedAtMillis: toMillis(data.capturedAt),
      matchedAtMillis: toMillis(data.matchedAt),
      thumbnailPath: typeof data.thumbnailPath === "string" ? data.thumbnailPath : null,
    };
  });

  photos.sort((a, b) => Number(b.capturedAtMillis || 0) - Number(a.capturedAtMillis || 0));
  return { eventId, photos };
});
