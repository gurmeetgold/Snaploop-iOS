const { onDocumentDeleted } = require("firebase-functions/v2/firestore");
const admin = require("firebase-admin");

const db = admin.firestore();
const Timestamp = admin.firestore.Timestamp;

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

async function scrubRemovedMember(eventId, userId) {
  const [matchedSnap, sourceSnap] = await Promise.all([
    db.collection(`events/${eventId}/photos`)
      .where("matchedUserIds", "array-contains", userId)
      .get(),
    db.collection(`events/${eventId}/photos`)
      .where("sourceUserId", "==", userId)
      .get(),
  ]);

  const sourceIds = new Set(sourceSnap.docs.map((doc) => doc.id));
  const operations = [];
  for (const doc of matchedSnap.docs) {
    if (sourceIds.has(doc.id)) continue;
    const data = doc.data() || {};
    const matchedFaceIdentityIds = data.matchedFaceIdentityIds && typeof data.matchedFaceIdentityIds === "object"
      ? { ...data.matchedFaceIdentityIds }
      : {};
    const matchedProfileRevisions = data.matchedProfileRevisions && typeof data.matchedProfileRevisions === "object"
      ? { ...data.matchedProfileRevisions }
      : {};
    const matchedMembershipIds = data.matchedMembershipIds && typeof data.matchedMembershipIds === "object"
      ? { ...data.matchedMembershipIds }
      : {};
    delete matchedFaceIdentityIds[userId];
    delete matchedProfileRevisions[userId];
    delete matchedMembershipIds[userId];

    operations.push({
      type: "update",
      ref: doc.ref,
      data: {
        appearances: Array.isArray(data.appearances)
          ? data.appearances.filter((appearance) => appearance.participantUserId !== userId)
          : [],
        matchedUserIds: Array.isArray(data.matchedUserIds)
          ? data.matchedUserIds.filter((uid) => uid !== userId)
          : [],
        // Change 4 binds photo visibility to stable face identity, exact Face
        // Setup revision and membership generation. Removal must scrub all three
        // maps as well as the visible appearance row; otherwise biometric-derived
        // metadata for someone who left the Event would remain orphaned.
        matchedFaceIdentityIds,
        matchedProfileRevisions,
        matchedMembershipIds,
        updatedAt: Timestamp.now(),
      },
    });
  }
  for (const doc of sourceSnap.docs) {
    operations.push({ type: "delete", ref: doc.ref });
  }
  await commitOperations(operations);

  try {
    await admin.storage().bucket().deleteFiles({ prefix: `events/${eventId}/photos/${userId}/` });
  } catch (error) {
    // The deleted membership already revokes Storage Rules access. Object
    // cleanup is idempotent and can be retried by a later administrative job.
    console.error("removed-member thumbnail cleanup failed", { eventId, userId, error });
  }
}

exports.cleanupRemovedMemberPhotoData = onDocumentDeleted(
  "events/{eventId}/members/{userId}",
  async (event) => {
    const { eventId, userId } = event.params;
    await scrubRemovedMember(eventId, userId);
  }
);
