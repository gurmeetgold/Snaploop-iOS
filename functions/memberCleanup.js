const { onDocumentDeleted } = require("firebase-functions/v2/firestore");
const admin = require("firebase-admin");
const { Timestamp } = require("firebase-admin/firestore");
const { normalizedMembershipId } = require("./membershipIdentity");
const { removeRecipientMatchMetadata } = require("./change4MatchMetadata");

const db = admin.firestore();

async function commitOperations(operations) {
  for (let offset = 0; offset < operations.length; offset += 400) {
    const batch = db.batch();
    for (const op of operations.slice(offset, offset + 400)) {
      if (op.type === "delete") batch.delete(op.ref);
      else batch.update(op.ref, op.data);
    }
    await batch.commit();
  }
}

function mapMembershipId(data, mapName, userId) {
  const map = data && data[mapName] && typeof data[mapName] === "object"
    ? data[mapName]
    : {};
  return normalizedMembershipId(map[userId]);
}

async function deleteOldThumbnailObjects(eventId, userId, paths) {
  const expectedPrefix = `events/${eventId}/photos/${userId}/`;
  const safe = [...new Set(paths)].filter((path) =>
    typeof path === "string" && path.startsWith(expectedPrefix)
  );
  if (!safe.length) return;

  const bucket = admin.storage().bucket();
  const results = await Promise.allSettled(safe.map((path) => bucket.file(path).delete()));
  const failures = results.filter((result) => result.status === "rejected");
  if (failures.length) {
    // Metadata is authoritative and already revoked. Never delete the whole user
    // prefix here: a fast rejoin may already have valid new-generation objects in
    // the same prefix.
    console.error("some removed-member thumbnails could not be deleted", {
      eventId,
      userId,
      failedCount: failures.length,
    });
  }
}

async function scrubRemovedMember(eventId, userId) {
  // The delete trigger can run after the same account has already rejoined. Read
  // the current member document first and preserve only data explicitly bound to
  // that new membership generation.
  const currentMemberSnap = await db.doc(`events/${eventId}/members/${userId}`).get();
  const currentMembershipId = currentMemberSnap.exists
    ? normalizedMembershipId((currentMemberSnap.data() || {}).membershipId)
    : null;

  const [matchedSnap, dismissedSnap, sourceSnap] = await Promise.all([
    db.collection(`events/${eventId}/photos`)
      .where("matchedUserIds", "array-contains", userId)
      .get(),
    db.collection(`events/${eventId}/photos`)
      .where("dismissedUserIds", "array-contains", userId)
      .get(),
    db.collection(`events/${eventId}/photos`)
      .where("sourceUserId", "==", userId)
      .get(),
  ]);

  const sourceById = new Map(sourceSnap.docs.map((doc) => [doc.id, doc]));
  const recipientById = new Map();
  for (const doc of [...matchedSnap.docs, ...dismissedSnap.docs]) recipientById.set(doc.id, doc);

  const operations = [];
  const objectPathsToDelete = [];

  for (const doc of recipientById.values()) {
    if (sourceById.has(doc.id)) continue;
    const data = doc.data() || {};
    const activeMembershipId = mapMembershipId(data, "matchedMembershipIds", userId);
    const dismissalMembershipId = mapMembershipId(data, "dismissedMembershipIds", userId);
    const belongsToCurrentGeneration = !!currentMembershipId
      && (activeMembershipId === currentMembershipId || dismissalMembershipId === currentMembershipId);
    if (belongsToCurrentGeneration) continue;

    operations.push({
      type: "update",
      ref: doc.ref,
      data: {
        ...removeRecipientMatchMetadata(data, userId, { removeDismissal: true }),
        updatedAt: Timestamp.now(),
      },
    });
  }

  for (const doc of sourceSnap.docs) {
    const data = doc.data() || {};
    const sourceMembershipId = normalizedMembershipId(data.sourceMembershipId);
    if (currentMembershipId && sourceMembershipId === currentMembershipId) {
      // This photo was published after the user rejoined. A delayed cleanup from
      // the old membership must not delete it.
      continue;
    }
    operations.push({ type: "delete", ref: doc.ref });
    if (typeof data.thumbnailPath === "string") objectPathsToDelete.push(data.thumbnailPath);
  }

  if (operations.length) await commitOperations(operations);
  await deleteOldThumbnailObjects(eventId, userId, objectPathsToDelete);
}

exports.cleanupRemovedMemberPhotoData = onDocumentDeleted(
  "events/{eventId}/members/{userId}",
  async (event) => {
    const { eventId, userId } = event.params;
    await scrubRemovedMember(eventId, userId);
  }
);