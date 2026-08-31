const { randomUUID } = require("crypto");
const { onCall, HttpsError } = require("firebase-functions/https");
const admin = require("firebase-admin");
const {
  dismissRecipientMatchMetadata,
  normalizedDismissedUserIds,
} = require("./change4MatchMetadata");

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

function requireBoolean(value, name) {
  if (typeof value !== "boolean") {
    throw new HttpsError("invalid-argument", `${name} must be true or false.`);
  }
  return value;
}

function photoDocumentId(matchId) {
  return Buffer.from(matchId, "utf8").toString("base64url");
}

async function commitDeletes(refs) {
  for (let offset = 0; offset < refs.length; offset += 400) {
    const batch = db.batch();
    for (const ref of refs.slice(offset, offset + 400)) batch.delete(ref);
    await batch.commit();
  }
}

async function deleteSourcePhotos(eventId, uid) {
  const snap = await db.collection(`events/${eventId}/photos`)
    .where("sourceUserId", "==", uid)
    .get();
  if (!snap.empty) await commitDeletes(snap.docs.map((doc) => doc.ref));

  try {
    await admin.storage().bucket().deleteFiles({ prefix: `events/${eventId}/photos/${uid}/` });
  } catch (error) {
    // Metadata removal immediately revokes reads. Object cleanup is best-effort
    // and can be retried by an idempotent sharing-off request.
    console.error("thumbnail cleanup failed after sharing was disabled", { eventId, uid, error });
  }
  return snap.size;
}

exports.setSharingIdentityBound = onCall(async (request) => {
  const uid = requireAuth(request);
  const data = request.data || {};
  const eventId = requireString(data.eventId, "eventId");
  const enabled = requireBoolean(data.enabled, "enabled");
  if (typeof data.userId === "string" && data.userId !== uid) {
    throw new HttpsError("permission-denied", "You can only change your own sharing setting.");
  }

  const memberRef = db.doc(`events/${eventId}/members/${uid}`);
  let changed = false;
  let sharingRevision = null;
  await db.runTransaction(async (tx) => {
    const snap = await tx.get(memberRef);
    if (!snap.exists) throw new HttpsError("permission-denied", "You are not a member of this Event.");
    const member = snap.data() || {};
    const currentEnabled = member.sharingEnabled !== false;
    const currentRevision = typeof member.sharingRevision === "string" && member.sharingRevision.trim()
      ? member.sharingRevision.trim()
      : null;

    if (currentEnabled === enabled) {
      sharingRevision = currentRevision;
      return;
    }

    changed = true;
    sharingRevision = randomUUID();
    tx.update(memberRef, {
      sharingEnabled: enabled,
      sharingRevision,
      sharingUpdatedAt: Timestamp.now(),
    });
  });

  let removedPhotos = 0;
  // Repeat cleanup even for an idempotent OFF request. This makes recovery from
  // a prior best-effort object cleanup failure safe without rotating the revision.
  if (!enabled) removedPhotos = await deleteSourcePhotos(eventId, uid);

  return { eventId, enabled, changed, sharingRevision, removedPhotos };
});

exports.dismissAppearanceIdentityBound = onCall(async (request) => {
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

  const memberSnap = await db.doc(`events/${eventId}/members/${uid}`).get();
  if (!memberSnap.exists) throw new HttpsError("permission-denied", "Join this Event first.");

  const photoRef = db.doc(`events/${eventId}/photos/${photoDocumentId(matchId)}`);
  await db.runTransaction(async (tx) => {
    const snap = await tx.get(photoRef);
    if (!snap.exists) throw new HttpsError("not-found", "That photo no longer exists.");
    const photo = snap.data() || {};
    if (photo.eventId !== eventId || photo.id !== matchId) {
      throw new HttpsError("failed-precondition", "That photo identity is inconsistent.");
    }

    const matched = Array.isArray(photo.matchedUserIds) && photo.matchedUserIds.includes(uid);
    const appeared = Array.isArray(photo.appearances)
      && photo.appearances.some((appearance) => appearance && appearance.participantUserId === uid);
    const alreadyDismissed = normalizedDismissedUserIds(photo).has(uid);
    if (!matched && !appeared && !alreadyDismissed) {
      throw new HttpsError("permission-denied", "You can only dismiss a photo matched to you.");
    }

    const cleaned = dismissRecipientMatchMetadata(photo, uid);
    tx.update(photoRef, {
      ...cleaned,
      updatedAt: Timestamp.now(),
    });
  });

  return { dismissed: true };
});
