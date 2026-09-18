const { onCall, HttpsError } = require("firebase-functions/https");
const admin = require("firebase-admin");
const { Timestamp, FieldValue } = require("firebase-admin/firestore");

const db = admin.firestore();

const MAX_APPEARANCES = 50;
const MAX_THUMBNAIL_BYTES = 5 * 1024 * 1024;
const MAX_CLOCK_SKEW_MS = 5 * 60 * 1000;
const MAX_DISPLAY_NAME_LENGTH = 20;

function requireAuth(request) {
  if (!request.auth || !request.auth.uid) {
    throw new HttpsError("unauthenticated", "You must be signed in.");
  }
  return request.auth.uid;
}

function requireString(value, name) {
  if (typeof value !== "string" || value.trim().length === 0) {
    throw new HttpsError("invalid-argument", `${name} is required.`);
  }
  return value.trim();
}

function requireMillis(value, name) {
  const n = Number(value);
  if (!Number.isFinite(n)) {
    throw new HttpsError("invalid-argument", `${name} is invalid.`);
  }
  return n;
}

function requireBoolean(value, name) {
  if (typeof value !== "boolean") {
    throw new HttpsError("invalid-argument", `${name} must be true or false.`);
  }
  return value;
}

function photoDocumentId(matchId) {
  return Buffer.from(matchId, "utf8").toString("base64url");
}

function expectedThumbnailPath(eventId, uid, docId) {
  return `events/${eventId}/photos/${uid}/${docId}/thumbnail.jpg`;
}

async function requireMember(eventId, uid) {
  const memberRef = db.doc(`events/${eventId}/members/${uid}`);
  const memberSnap = await memberRef.get();
  if (!memberSnap.exists) {
    throw new HttpsError("permission-denied", "Join this event first.");
  }
  return { memberRef, member: memberSnap.data() || {} };
}

async function commitOperations(operations) {
  for (let offset = 0; offset < operations.length; offset += 400) {
    const batch = db.batch();
    for (const op of operations.slice(offset, offset + 400)) {
      if (op.type === "delete") batch.delete(op.ref);
      else if (op.type === "update") batch.update(op.ref, op.data);
      else if (op.type === "set") batch.set(op.ref, op.data, op.options || {});
    }
    await batch.commit();
  }
}

async function deleteCollection(path) {
  const snap = await db.collection(path).get();
  const operations = snap.docs.map((doc) => ({ type: "delete", ref: doc.ref }));
  await commitOperations(operations);
}

async function scrubUserFromEventPhotos(eventId, uid) {
  const snap = await db.collection(`events/${eventId}/photos`)
    .where("matchedUserIds", "array-contains", uid)
    .get();

  const operations = snap.docs.map((doc) => {
    const data = doc.data() || {};
    const appearances = Array.isArray(data.appearances)
      ? data.appearances.filter((appearance) => appearance.participantUserId !== uid)
      : [];
    const matchedUserIds = Array.isArray(data.matchedUserIds)
      ? data.matchedUserIds.filter((userId) => userId !== uid)
      : [];
    return {
      type: "update",
      ref: doc.ref,
      data: { appearances, matchedUserIds, updatedAt: Timestamp.now() },
    };
  });
  await commitOperations(operations);
  return operations.length;
}

async function deleteSourcePhotos(eventId, uid) {
  const snap = await db.collection(`events/${eventId}/photos`)
    .where("sourceUserId", "==", uid)
    .get();
  await commitOperations(snap.docs.map((doc) => ({ type: "delete", ref: doc.ref })));

  try {
    await admin.storage().bucket().deleteFiles({ prefix: `events/${eventId}/photos/${uid}/` });
  } catch (error) {
    // Metadata is authoritative. Storage cleanup is best-effort; Storage Rules
    // deny reads as soon as sharing is disabled or the backing photo doc is gone.
    console.error("thumbnail cleanup failed", { eventId, uid, error });
  }
  return snap.size;
}

async function eraseFaceData(uid, withdrawConsent) {
  const userRef = db.doc(`users/${uid}`);
  const eventRefs = await userRef.collection("eventRefs").get();
  let scrubbedPhotos = 0;
  let rosterEntriesRemoved = 0;

  for (const eventRefDoc of eventRefs.docs) {
    const eventId = eventRefDoc.id;
    const participantRef = db.doc(`events/${eventId}/participants/${uid}`);
    const participantSnap = await participantRef.get();
    if (participantSnap.exists) {
      await participantRef.delete();
      rosterEntriesRemoved += 1;
    }
    scrubbedPhotos += await scrubUserFromEventPhotos(eventId, uid);
  }

  const batch = db.batch();
  batch.delete(db.doc(`users/${uid}/faceProfile/current`));
  batch.set(userRef, { hasFaceProfile: false }, { merge: true });
  if (withdrawConsent) {
    batch.set(
      db.doc(`users/${uid}/privacy/biometricConsent`),
      { withdrawnAt: Timestamp.now() },
      { merge: true }
    );
  }
  await batch.commit();

  return { scrubbedPhotos, rosterEntriesRemoved };
}

async function deleteOwnedEvent(eventId, event) {
  const membersSnap = await db.collection(`events/${eventId}/members`).get();
  const userRefDeletes = membersSnap.docs.map((member) => ({
    type: "delete",
    ref: db.doc(`users/${member.id}/eventRefs/${eventId}`),
  }));
  await commitOperations(userRefDeletes);

  await Promise.all([
    deleteCollection(`events/${eventId}/members`),
    deleteCollection(`events/${eventId}/participants`),
    deleteCollection(`events/${eventId}/photos`),
    deleteCollection(`events/${eventId}/invites`),
  ]);

  const lookupOps = [];
  if (event && typeof event.joinCode === "string" && event.joinCode) {
    lookupOps.push({ type: "delete", ref: db.doc(`joinCodes/${event.joinCode}`) });
  }
  if (event && typeof event.inviteToken === "string" && event.inviteToken) {
    lookupOps.push({ type: "delete", ref: db.doc(`inviteTokens/${event.inviteToken}`) });
  }
  if (lookupOps.length) await commitOperations(lookupOps);

  await db.doc(`events/${eventId}`).delete();
  try {
    await admin.storage().bucket().deleteFiles({ prefix: `events/${eventId}/` });
  } catch (error) {
    console.error("event storage cleanup failed", { eventId, error });
  }
}

exports.syncMyUserProfile = onCall(async (request) => {
  const uid = requireAuth(request);
  const data = request.data || {};
  if (typeof data.userId === "string" && data.userId !== uid) {
    throw new HttpsError("permission-denied", "User identity does not match the signed-in user.");
  }

  const authUser = await admin.auth().getUser(uid);
  if (!authUser.phoneNumber) {
    throw new HttpsError("failed-precondition", "A verified phone number is required.");
  }

  let displayName = null;
  if (data.displayName !== undefined && data.displayName !== null) {
    displayName = requireString(data.displayName, "displayName");
    if (displayName.length < 2 || displayName.length > MAX_DISPLAY_NAME_LENGTH) {
      throw new HttpsError("invalid-argument", `Display name must be between 2 and ${MAX_DISPLAY_NAME_LENGTH} characters.`);
    }
  }

  const userRef = db.doc(`users/${uid}`);
  const [existing, profile] = await Promise.all([
    userRef.get(),
    db.doc(`users/${uid}/faceProfile/current`).get(),
  ]);
  const current = existing.exists ? existing.data() || {} : {};

  await userRef.set({
    id: uid,
    phoneNumber: authUser.phoneNumber,
    displayName,
    hasFaceProfile: profile.exists,
    createdAt: current.createdAt instanceof Timestamp ? current.createdAt : Timestamp.now(),
    updatedAt: Timestamp.now(),
  }, { merge: true });

  return {
    userId: uid,
    phoneNumber: authUser.phoneNumber,
    displayName,
    hasFaceProfile: profile.exists,
  };
});

exports.updateDisplayNameTrusted = onCall(async (request) => {
  const uid = requireAuth(request);
  const displayName = requireString((request.data || {}).displayName, "displayName");
  if (displayName.length < 2 || displayName.length > MAX_DISPLAY_NAME_LENGTH) {
    throw new HttpsError("invalid-argument", `Display name must be between 2 and ${MAX_DISPLAY_NAME_LENGTH} characters.`);
  }

  const userRef = db.doc(`users/${uid}`);
  await userRef.set({ displayName, updatedAt: Timestamp.now() }, { merge: true });
  const eventRefs = await userRef.collection("eventRefs").get();
  const operations = [];
  for (const eventRefDoc of eventRefs.docs) {
    const participantRef = db.doc(`events/${eventRefDoc.id}/participants/${uid}`);
    const participantSnap = await participantRef.get();
    if (participantSnap.exists) {
      operations.push({ type: "update", ref: participantRef, data: { displayName } });
    }
  }
  await commitOperations(operations);
  return { displayName };
});

exports.setSharingManaged = onCall(async (request) => {
  const uid = requireAuth(request);
  const data = request.data || {};
  const eventId = requireString(data.eventId, "eventId");
  const enabled = requireBoolean(data.enabled, "enabled");
  if (typeof data.userId === "string" && data.userId !== uid) {
    throw new HttpsError("permission-denied", "You can only change your own sharing setting.");
  }

  const { memberRef } = await requireMember(eventId, uid);
  await memberRef.update({ sharingEnabled: enabled, sharingUpdatedAt: Timestamp.now() });

  let removedPhotos = 0;
  if (!enabled) {
    removedPhotos = await deleteSourcePhotos(eventId, uid);
  }

  return { eventId, enabled, removedPhotos };
});

exports.publishMatch = onCall(async (request) => {
  const uid = requireAuth(request);
  const data = request.data || {};
  const eventId = requireString(data.eventId, "eventId");
  const assetLocalId = requireString(data.assetLocalId, "assetLocalId");
  const matchId = requireString(data.id, "id");
  const canonicalMatchId = `${eventId}:${assetLocalId}`;
  if (matchId !== canonicalMatchId) {
    throw new HttpsError("invalid-argument", "Photo identity is invalid.");
  }

  const { member } = await requireMember(eventId, uid);
  if (member.sharingEnabled === false) {
    throw new HttpsError("failed-precondition", "Photo sharing is turned off for this event.");
  }

  const eventSnap = await db.doc(`events/${eventId}`).get();
  if (!eventSnap.exists) throw new HttpsError("not-found", "This event does not exist.");
  const event = eventSnap.data() || {};
  if (event.status !== "active") throw new HttpsError("failed-precondition", "This event has ended.");

  const capturedAtMillis = requireMillis(data.capturedAtMillis, "capturedAt");
  const matchedAtMillis = requireMillis(data.matchedAtMillis, "matchedAt");
  if (matchedAtMillis > Date.now() + MAX_CLOCK_SKEW_MS) {
    throw new HttpsError("invalid-argument", "Match time is invalid.");
  }
  if (event.startsAt instanceof Timestamp && capturedAtMillis < event.startsAt.toMillis()) {
    throw new HttpsError("invalid-argument", "Photo is outside the event date range.");
  }
  if (event.endsAt instanceof Timestamp && capturedAtMillis > event.endsAt.toMillis()) {
    throw new HttpsError("invalid-argument", "Photo is outside the event date range.");
  }

  if (!Array.isArray(data.appearances) || data.appearances.length > MAX_APPEARANCES) {
    throw new HttpsError("invalid-argument", "Appearances are invalid.");
  }

  const seen = new Set();
  const appearances = data.appearances.map((raw) => {
    const participantUserId = requireString(raw && raw.participantUserId, "participantUserId");
    const confidence = Number(raw && raw.confidence);
    if (!Number.isFinite(confidence) || confidence < 0 || confidence > 1) {
      throw new HttpsError("invalid-argument", "Appearance confidence is invalid.");
    }
    if (seen.has(participantUserId)) {
      throw new HttpsError("invalid-argument", "Duplicate participant appearance.");
    }
    seen.add(participantUserId);
    return { participantUserId, confidence, dismissedByUser: false };
  });

  if (appearances.length > 0) {
    const refs = appearances.map((appearance) =>
      db.doc(`events/${eventId}/members/${appearance.participantUserId}`)
    );
    const snaps = await db.getAll(...refs);
    if (snaps.some((snap) => !snap.exists)) {
      throw new HttpsError("invalid-argument", "A matched person is not a member of this event.");
    }
  }

  const docId = photoDocumentId(matchId);
  const thumbnailPath = requireString(data.thumbnailPath, "thumbnailPath");
  const expectedPath = expectedThumbnailPath(eventId, uid, docId);
  if (thumbnailPath !== expectedPath) {
    throw new HttpsError("invalid-argument", "Thumbnail path is invalid.");
  }

  try {
    const [metadata] = await admin.storage().bucket().file(thumbnailPath).getMetadata();
    const size = Number(metadata.size || 0);
    if (metadata.contentType !== "image/jpeg" || !Number.isFinite(size) || size <= 0 || size > MAX_THUMBNAIL_BYTES) {
      throw new Error("invalid thumbnail metadata");
    }
  } catch (error) {
    console.error("thumbnail verification failed", { eventId, uid, thumbnailPath, error });
    throw new HttpsError("failed-precondition", "Thumbnail upload could not be verified.");
  }

  await db.doc(`events/${eventId}/photos/${docId}`).set({
    id: matchId,
    eventId,
    sourceUserId: uid,
    assetLocalId,
    appearances,
    matchedUserIds: appearances.map((appearance) => appearance.participantUserId),
    capturedAt: Timestamp.fromMillis(capturedAtMillis),
    matchedAt: Timestamp.fromMillis(matchedAtMillis),
    thumbnailPath,
    createdAt: Timestamp.now(),
    updatedAt: Timestamp.now(),
  }, { merge: false });

  return { eventId, photoId: docId };
});

exports.dismissAppearanceTrusted = onCall(async (request) => {
  const uid = requireAuth(request);
  const data = request.data || {};
  const eventId = requireString(data.eventId, "eventId");
  const matchId = requireString(data.matchId, "matchId");
  if (!matchId.startsWith(`${eventId}:`)) {
    throw new HttpsError("invalid-argument", "Photo identity is invalid.");
  }
  if (typeof data.participantUserId === "string" && data.participantUserId !== uid) {
    throw new HttpsError("permission-denied", "You can only dismiss your own appearance.");
  }
  await requireMember(eventId, uid);

  const photoRef = db.doc(`events/${eventId}/photos/${photoDocumentId(matchId)}`);
  await db.runTransaction(async (tx) => {
    const snap = await tx.get(photoRef);
    if (!snap.exists) throw new HttpsError("not-found", "That photo no longer exists.");
    const photo = snap.data() || {};
    const appearances = Array.isArray(photo.appearances)
      ? photo.appearances.map((appearance) =>
          appearance.participantUserId === uid
            ? { ...appearance, dismissedByUser: true }
            : appearance
        )
      : [];
    const matchedUserIds = Array.isArray(photo.matchedUserIds)
      ? photo.matchedUserIds.filter((userId) => userId !== uid)
      : [];
    tx.update(photoRef, { appearances, matchedUserIds, updatedAt: Timestamp.now() });
  });
  return { dismissed: true };
});

exports.eraseMyFaceProfile = onCall(async (request) => {
  const uid = requireAuth(request);
  const result = await eraseFaceData(uid, false);
  return { erased: true, ...result };
});

exports.withdrawBiometricConsent = onCall(async (request) => {
  const uid = requireAuth(request);
  const result = await eraseFaceData(uid, true);
  return { withdrawn: true, ...result };
});

exports.deleteMyAccount = onCall(async (request) => {
  const uid = requireAuth(request);
  const userRef = db.doc(`users/${uid}`);
  const eventRefs = await userRef.collection("eventRefs").get();

  for (const eventRefDoc of eventRefs.docs) {
    const eventId = eventRefDoc.id;
    const [eventSnap, memberSnap] = await Promise.all([
      db.doc(`events/${eventId}`).get(),
      db.doc(`events/${eventId}/members/${uid}`).get(),
    ]);
    if (!eventSnap.exists) continue;
    const event = eventSnap.data() || {};
    const role = memberSnap.exists ? memberSnap.data().role : eventRefDoc.data().role;

    if (role === "organizer" || event.creatorUserId === uid) {
      await deleteOwnedEvent(eventId, event);
      continue;
    }

    await scrubUserFromEventPhotos(eventId, uid);
    await deleteSourcePhotos(eventId, uid);
    await db.runTransaction(async (tx) => {
      const eventRef = db.doc(`events/${eventId}`);
      const freshEvent = await tx.get(eventRef);
      if (!freshEvent.exists) return;
      const count = Math.max(0, Number(freshEvent.data().memberCount || 1) - 1);
      tx.delete(db.doc(`events/${eventId}/members/${uid}`));
      tx.delete(db.doc(`events/${eventId}/participants/${uid}`));
      tx.delete(db.doc(`users/${uid}/eventRefs/${eventId}`));
      tx.update(eventRef, { memberCount: count, updatedAt: Timestamp.now() });
    });
  }

  await Promise.all([
    deleteCollection(`users/${uid}/eventRefs`),
    deleteCollection(`users/${uid}/pendingInvites`),
    deleteCollection(`users/${uid}/notifications`),
    deleteCollection(`users/${uid}/faceProfile`),
    deleteCollection(`users/${uid}/privacy`),
  ]);
  await userRef.delete();

  try {
    await admin.auth().deleteUser(uid);
  } catch (error) {
    console.error("auth deletion failed after data purge", { uid, error });
    throw new HttpsError("internal", "Your data was removed, but authentication cleanup needs to be retried.");
  }

  return { deleted: true };
});