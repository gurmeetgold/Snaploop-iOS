const { onCall, HttpsError } = require("firebase-functions/https");
const admin = require("firebase-admin");
const { Timestamp } = require("firebase-admin/firestore");

const db = admin.firestore();

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

async function scrubMemberPhotoData(eventId, targetUid) {
  const [matchedSnap, sourceSnap] = await Promise.all([
    db.collection(`events/${eventId}/photos`)
      .where("matchedUserIds", "array-contains", targetUid)
      .get(),
    db.collection(`events/${eventId}/photos`)
      .where("sourceUserId", "==", targetUid)
      .get(),
  ]);

  const sourceIds = new Set(sourceSnap.docs.map((doc) => doc.id));
  const operations = [];
  for (const doc of matchedSnap.docs) {
    if (sourceIds.has(doc.id)) continue;
    const data = doc.data() || {};
    operations.push({
      type: "update",
      ref: doc.ref,
      data: {
        appearances: Array.isArray(data.appearances)
          ? data.appearances.filter((appearance) => appearance.participantUserId !== targetUid)
          : [],
        matchedUserIds: Array.isArray(data.matchedUserIds)
          ? data.matchedUserIds.filter((uid) => uid !== targetUid)
          : [],
        updatedAt: Timestamp.now(),
      },
    });
  }
  for (const doc of sourceSnap.docs) {
    operations.push({ type: "delete", ref: doc.ref });
  }
  await commitOperations(operations);

  try {
    await admin.storage().bucket().deleteFiles({ prefix: `events/${eventId}/photos/${targetUid}/` });
  } catch (error) {
    // Membership removal already blocks the path in Storage Rules. Object
    // deletion is best-effort cleanup and can be retried administratively.
    console.error("member thumbnail cleanup failed", { eventId, targetUid, error });
  }
}

async function notifyRemainingMembers(eventId, actorUid, body) {
  const [eventSnap, membersSnap] = await Promise.all([
    db.doc(`events/${eventId}`).get(),
    db.collection(`events/${eventId}/members`).get(),
  ]);
  const title = eventSnap.exists ? (eventSnap.data().name || "MyPicsRoom event") : "MyPicsRoom event";
  const batch = db.batch();
  let count = 0;
  for (const member of membersSnap.docs) {
    if (member.id === actorUid) continue;
    batch.set(db.collection(`users/${member.id}/notifications`).doc(), {
      type: "member_removed",
      eventId,
      eventName: title,
      title,
      body,
      createdAt: Timestamp.now(),
      read: false,
    });
    count += 1;
  }
  if (count > 0) await batch.commit();
}

/// Backward-compatible replacement for the legacy leaveEvent callable. A user
/// may leave themselves, an Organizer may remove any non-Organizer, and an
/// Admin may remove an ordinary Member. The unique Organizer cannot be removed.
exports.leaveEventManaged = onCall(async (request) => {
  const actorUid = requireAuth(request);
  const data = request.data || {};
  const eventId = requireString(data.eventId, "eventId");
  const targetUid = requireString(data.userId || actorUid, "userId");

  const eventRef = db.doc(`events/${eventId}`);
  const actorRef = db.doc(`events/${eventId}/members/${actorUid}`);
  const targetRef = db.doc(`events/${eventId}/members/${targetUid}`);
  const participantRef = db.doc(`events/${eventId}/participants/${targetUid}`);
  const userEventRef = db.doc(`users/${targetUid}/eventRefs/${eventId}`);
  let changed = false;

  await db.runTransaction(async (tx) => {
    const [eventSnap, actorSnap, targetSnap] = await Promise.all([
      tx.get(eventRef),
      tx.get(actorRef),
      tx.get(targetRef),
    ]);

    if (!eventSnap.exists) throw new HttpsError("not-found", "This event does not exist.");
    if (!targetSnap.exists) return;

    const actorRole = actorSnap.exists ? actorSnap.data().role : null;
    const targetRole = targetSnap.data().role;
    if (targetRole === "organizer") {
      throw new HttpsError("failed-precondition", "The organizer cannot be removed.");
    }

    const removingSelf = actorUid === targetUid;
    const organizerCanRemove = actorRole === "organizer";
    const adminCanRemove = actorRole === "admin" && targetRole === "participant";
    if (!removingSelf && !organizerCanRemove && !adminCanRemove) {
      throw new HttpsError("permission-denied", "You cannot remove this member.");
    }

    const memberCount = Math.max(0, Number(eventSnap.data().memberCount || 1) - 1);
    tx.delete(targetRef);
    tx.delete(participantRef);
    tx.delete(userEventRef);
    tx.update(eventRef, { memberCount, updatedAt: Timestamp.now() });
    changed = true;
  });

  if (changed) {
    await scrubMemberPhotoData(eventId, targetUid);
    await notifyRemainingMembers(eventId, actorUid, "A member left or was removed from the event.");
  }
  return { eventId, userId: targetUid, changed };
});
