const { onDocumentWritten } = require("firebase-functions/v2/firestore");
const admin = require("firebase-admin");
const { Timestamp } = require("firebase-admin/firestore");
const { removeRecipientMatchMetadata } = require("./change4MatchMetadata");

const db = admin.firestore();

function profileIdentity(profile) {
  return profile && typeof profile.faceIdentityId === "string" ? profile.faceIdentityId.trim() : "";
}

function profileRevision(profile) {
  if (!profile || typeof profile !== "object") return null;
  const version = Number(profile.version || 0);
  const ids = (Array.isArray(profile.templates) ? profile.templates : [])
    .map((item) => item && typeof item.id === "string" ? item.id.trim() : "")
    .filter(Boolean)
    .sort();
  return version > 0 && ids.length ? `v${version}:${ids.join("|")}` : null;
}

async function commitUpdates(items) {
  for (let offset = 0; offset < items.length; offset += 400) {
    const batch = db.batch();
    for (const item of items.slice(offset, offset + 400)) batch.update(item.ref, item.data);
    await batch.commit();
  }
}

function photoBelongsToIdentity(photo, uid, oldIdentity) {
  const identityMap = photo.matchedFaceIdentityIds && typeof photo.matchedFaceIdentityIds === "object"
    ? photo.matchedFaceIdentityIds
    : {};
  const mapped = typeof identityMap[uid] === "string" ? identityMap[uid].trim() : "";
  if (mapped) return mapped === oldIdentity;

  // Legacy fallback: before identity maps existed, an appearance may contain its
  // own identity or no identity at all. If we cannot prove the row belongs to a
  // newer identity, fail closed and remove it.
  const appearance = Array.isArray(photo.appearances)
    ? photo.appearances.find((item) => item && item.participantUserId === uid)
    : null;
  if (!appearance) return false;
  const embedded = typeof appearance.faceIdentityId === "string" ? appearance.faceIdentityId.trim() : "";
  return !embedded || embedded === oldIdentity;
}

async function scrubOldIdentityMatches(uid, oldIdentity) {
  const eventRefs = await db.collection(`users/${uid}/eventRefs`).get();
  let scrubbed = 0;

  for (const eventRef of eventRefs.docs) {
    const eventId = eventRef.id;
    const snap = await db.collection(`events/${eventId}/photos`)
      .where("matchedUserIds", "array-contains", uid)
      .get();
    const updates = [];
    for (const doc of snap.docs) {
      const photo = doc.data() || {};
      if (!photoBelongsToIdentity(photo, uid, oldIdentity)) continue;
      updates.push({
        ref: doc.ref,
        data: {
          ...removeRecipientMatchMetadata(photo, uid),
          updatedAt: Timestamp.now(),
        },
      });
    }
    if (updates.length) {
      await commitUpdates(updates);
      scrubbed += updates.length;
    }
  }
  return scrubbed;
}

exports.scrubMatchesOnFaceProfileChange = onDocumentWritten(
  "users/{userId}/faceProfile/current",
  async (event) => {
    const uid = event.params.userId;
    const before = event.data && event.data.before && event.data.before.exists
      ? event.data.before.data() || {}
      : null;
    const after = event.data && event.data.after && event.data.after.exists
      ? event.data.after.data() || {}
      : null;
    const beforeIdentity = profileIdentity(before);
    const afterIdentity = profileIdentity(after);

    if (beforeIdentity && beforeIdentity !== afterIdentity) {
      const scrubbedPhotos = await scrubOldIdentityMatches(uid, beforeIdentity);
      console.log("Old face identity matches scrubbed without touching a newer identity", { scrubbedPhotos });
      return;
    }

    if (beforeIdentity && beforeIdentity === afterIdentity
        && profileRevision(before) !== profileRevision(after)) {
      console.log("Face Setup refreshed for the same identity; existing positive matches preserved");
    }
  }
);

exports._test = {
  photoBelongsToIdentity,
};
