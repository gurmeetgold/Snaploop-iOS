const { randomUUID } = require("crypto");
const { onCall, HttpsError } = require("firebase-functions/https");
const admin = require("firebase-admin");
const { Timestamp } = require("firebase-admin/firestore");
const { removeRecipientMatchMetadata } = require("./change4MatchMetadata");

const db = admin.firestore();

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

async function hasActiveFaceSetup(uid) {
  const snap = await db.doc(`users/${uid}/faceProfile/current`).get();
  if (!snap.exists) return false;
  const data = snap.data() || {};
  return typeof data.faceIdentityId === "string" && data.faceIdentityId.trim().length > 0;
}

async function commitUpdates(items) {
  for (let offset = 0; offset < items.length; offset += 400) {
    const batch = db.batch();
    for (const item of items.slice(offset, offset + 400)) batch.update(item.ref, item.data);
    await batch.commit();
  }
}

async function disableOwnMatchesEverywhereFor(uid) {
  const eventRefs = await db.collection(`users/${uid}/eventRefs`).get();
  let changed = 0;
  for (const eventRef of eventRefs.docs) {
    const memberRef = db.doc(`events/${eventRef.id}/members/${uid}`);
    const member = await memberRef.get();
    if (!member.exists || member.data()?.includeOwnMatches !== true) continue;
    await memberRef.update({
      includeOwnMatches: false,
      ownMatchesRevision: randomUUID(),
      ownMatchesUpdatedAt: Timestamp.now(),
    });
    changed += 1;
  }
  return changed;
}

exports.getMemberPhotoPreferences = onCall(async (request) => {
  const uid = requireAuth(request);
  const eventId = requireEventId(request);
  const { data } = await requireMembership(eventId, uid);
  const sharingEnabled = data.sharingEnabled !== false;
  const sharingRevision = typeof data.sharingRevision === "string" && data.sharingRevision.trim()
    ? data.sharingRevision.trim()
    : null;
  const ownMatchesRevision = typeof data.ownMatchesRevision === "string" && data.ownMatchesRevision.trim()
    ? data.ownMatchesRevision.trim()
    : null;

  return {
    eventId,
    sharingEnabled,
    includeOwnMatches: sharingEnabled && data.includeOwnMatches === true,
    sharingRevision,
    ownMatchesRevision,
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

  const { ref, data } = await requireMembership(eventId, uid);
  if (enabled && data.sharingEnabled === false) {
    throw new HttpsError(
      "failed-precondition",
      "Turn on photo sharing for this Event before showing your own matched photos."
    );
  }
  if (enabled && !(await hasActiveFaceSetup(uid))) {
    throw new HttpsError(
      "failed-precondition",
      "Set up your face to see your own photo matches."
    );
  }

  if (data.includeOwnMatches !== enabled) {
    await ref.update({
      includeOwnMatches: enabled,
      ownMatchesRevision: randomUUID(),
      ownMatchesUpdatedAt: Timestamp.now(),
    });
  }

  // Turning this off hides existing photos sourced from this account from the
  // owner's own Gallery while preserving every other recipient and preserving a
  // prior explicit Not-Me tombstone. The ownMatchesRevision changes on both OFF
  // and ON, so the source device can invalidate only its own recipient cursor on
  // the next scan even if no scan happened while the setting was OFF.
  if (!enabled) {
    const sourceSnap = await db.collection(`events/${eventId}/photos`)
      .where("sourceUserId", "==", uid)
      .get();

    const updates = [];
    for (const doc of sourceSnap.docs) {
      const photo = doc.data() || {};
      const matched = Array.isArray(photo.matchedUserIds) ? photo.matchedUserIds : [];
      const appeared = Array.isArray(photo.appearances)
        && photo.appearances.some((appearance) => appearance && appearance.participantUserId === uid);
      if (!matched.includes(uid) && !appeared) continue;
      updates.push({
        ref: doc.ref,
        data: {
          ...removeRecipientMatchMetadata(photo, uid),
          updatedAt: Timestamp.now(),
        },
      });
    }
    if (updates.length) await commitUpdates(updates);
  }

  return { eventId, includeOwnMatches: enabled };
});

exports.disableOwnMatchesEverywhere = onCall(async (request) => {
  const uid = requireAuth(request);
  const changed = await disableOwnMatchesEverywhereFor(uid);
  return { changed };
});
