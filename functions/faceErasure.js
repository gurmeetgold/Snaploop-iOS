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

async function commitUpdates(items) {
  for (let offset = 0; offset < items.length; offset += 400) {
    const batch = db.batch();
    for (const item of items.slice(offset, offset + 400)) batch.update(item.ref, item.data);
    await batch.commit();
  }
}

async function scrubUserFromEventPhotos(eventId, uid) {
  const snap = await db.collection(`events/${eventId}/photos`)
    .where("matchedUserIds", "array-contains", uid)
    .get();
  const updates = snap.docs.map((doc) => {
    const data = doc.data() || {};
    const appearances = Array.isArray(data.appearances)
      ? data.appearances.filter((appearance) => appearance.participantUserId !== uid)
      : [];
    const matchedUserIds = Array.isArray(data.matchedUserIds)
      ? data.matchedUserIds.filter((userId) => userId !== uid)
      : [];
    const matchedProfileRevisions = data.matchedProfileRevisions && typeof data.matchedProfileRevisions === "object"
      ? { ...data.matchedProfileRevisions }
      : {};
    delete matchedProfileRevisions[uid];
    return {
      ref: doc.ref,
      data: { appearances, matchedUserIds, matchedProfileRevisions, updatedAt: Timestamp.now() },
    };
  });
  if (updates.length) await commitUpdates(updates);
  return updates.length;
}

// Deleting Face Setup removes the active biometric identity and also
// deactivates its current consent authorization. The versioned historical
// consent record remains as audit evidence, but cannot authorize a future Face
// Setup; the user must expressly consent again before re-enrolling.
exports.eraseMyFaceProfileIdentityBound = onCall(async (request) => {
  const uid = requireAuth(request);
  if (typeof (request.data || {}).userId === "string" && request.data.userId !== uid) {
    throw new HttpsError("permission-denied", "You can only delete your own Face Setup.");
  }

  const userRef = db.doc(`users/${uid}`);
  const eventRefs = await userRef.collection("eventRefs").get();
  let scrubbedPhotos = 0;
  let rosterEntriesRemoved = 0;

  for (const eventRef of eventRefs.docs) {
    const eventId = eventRef.id;
    const participantRef = db.doc(`events/${eventId}/participants/${uid}`);
    const participant = await participantRef.get();
    if (participant.exists) {
      await participantRef.delete();
      rosterEntriesRemoved += 1;
    }
    scrubbedPhotos += await scrubUserFromEventPhotos(eventId, uid);
  }

  const batch = db.batch();
  batch.delete(db.doc(`users/${uid}/faceProfile/current`));
  batch.set(userRef, { hasFaceProfile: false, updatedAt: Timestamp.now() }, { merge: true });
  batch.set(db.doc(`users/${uid}/privacy/biometricConsent`), {
    withdrawnAt: Timestamp.now(),
    withdrawalReason: "face-setup-deleted",
  }, { merge: true });
  await batch.commit();

  return {
    erased: true,
    consentDeactivated: true,
    scrubbedPhotos,
    rosterEntriesRemoved,
  };
});
