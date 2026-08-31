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
    const matchedFaceIdentityIds = data.matchedFaceIdentityIds && typeof data.matchedFaceIdentityIds === "object"
      ? { ...data.matchedFaceIdentityIds }
      : {};
    const matchedProfileRevisions = data.matchedProfileRevisions && typeof data.matchedProfileRevisions === "object"
      ? { ...data.matchedProfileRevisions }
      : {};
    const matchedMembershipIds = data.matchedMembershipIds && typeof data.matchedMembershipIds === "object"
      ? { ...data.matchedMembershipIds }
      : {};
    delete matchedFaceIdentityIds[uid];
    delete matchedProfileRevisions[uid];
    delete matchedMembershipIds[uid];
    return {
      ref: doc.ref,
      data: {
        appearances,
        matchedUserIds,
        matchedFaceIdentityIds,
        matchedProfileRevisions,
        matchedMembershipIds,
        updatedAt: Timestamp.now(),
      },
    };
  });
  if (updates.length) await commitUpdates(updates);
  return updates.length;
}

async function eraseIdentityBound(uid, withdrawalReason) {
  const userRef = db.doc(`users/${uid}`);
  const eventRefs = await userRef.collection("eventRefs").get();
  let scrubbedPhotos = 0;
  let rosterEntriesRemoved = 0;
  let ownMatchPreferencesDisabled = 0;

  for (const eventRef of eventRefs.docs) {
    const eventId = eventRef.id;
    const participantRef = db.doc(`events/${eventId}/participants/${uid}`);
    const memberRef = db.doc(`events/${eventId}/members/${uid}`);
    const [participant, member] = await Promise.all([participantRef.get(), memberRef.get()]);

    if (participant.exists) {
      await participantRef.delete();
      rosterEntriesRemoved += 1;
    }
    if (member.exists) {
      await memberRef.update({ includeOwnMatches: false, ownMatchesUpdatedAt: Timestamp.now() });
      ownMatchPreferencesDisabled += 1;
    }
    scrubbedPhotos += await scrubUserFromEventPhotos(eventId, uid);
  }

  const now = Timestamp.now();
  const batch = db.batch();
  batch.delete(db.doc(`users/${uid}/faceProfile/current`));
  batch.set(userRef, { hasFaceProfile: false, updatedAt: now }, { merge: true });
  batch.set(db.doc(`users/${uid}/privacy/biometricConsent`), {
    withdrawnAt: now,
    withdrawalReason,
  }, { merge: true });
  await batch.commit();

  return {
    consentDeactivated: true,
    scrubbedPhotos,
    rosterEntriesRemoved,
    ownMatchPreferencesDisabled,
  };
}

// Deleting Face Setup is the explicit identity boundary. It removes the active
// biometric identity, scrubs every face/membership-derived photo association,
// turns off the user's own-match preference in every Event, and deactivates
// current consent. A future Face Setup therefore requires fresh consent and gets
// a new server-issued faceIdentityId.
exports.eraseMyFaceProfileIdentityBound = onCall(async (request) => {
  const uid = requireAuth(request);
  if (typeof (request.data || {}).userId === "string" && request.data.userId !== uid) {
    throw new HttpsError("permission-denied", "You can only delete your own Face Setup.");
  }

  const result = await eraseIdentityBound(uid, "face-setup-deleted");
  return { erased: true, ...result };
});

// Explicit consent withdrawal must use the same identity-bound erasure path.
// The former generic security handler removed matchedUserIds before the profile
// trigger ran, which could strand Change-4 identity/revision/membership maps.
exports.withdrawBiometricConsentIdentityBound = onCall(async (request) => {
  const uid = requireAuth(request);
  if (typeof (request.data || {}).userId === "string" && request.data.userId !== uid) {
    throw new HttpsError("permission-denied", "You can only withdraw your own biometric consent.");
  }

  const result = await eraseIdentityBound(uid, "biometric-consent-withdrawn");
  return { withdrawn: true, erased: true, ...result };
});
