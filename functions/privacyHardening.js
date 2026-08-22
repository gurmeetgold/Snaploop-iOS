const { onCall, HttpsError } = require("firebase-functions/https");
const { onDocumentWritten } = require("firebase-functions/v2/firestore");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const admin = require("firebase-admin");

const db = admin.firestore();
const Timestamp = admin.firestore.Timestamp;
const FieldValue = admin.firestore.FieldValue;

const DAY_MS = 24 * 60 * 60 * 1000;
const PREVIEW_RETENTION_DAYS = 10;
// Run deletion early enough that an hourly scheduler still completes within the
// public seven-day deletion commitment even with ordinary execution jitter.
const DELETED_TRIP_HARD_DELETE_AFTER_MS = (6 * DAY_MS) + (12 * 60 * 60 * 1000);

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

async function commitDeletes(refs) {
  for (let offset = 0; offset < refs.length; offset += 400) {
    const batch = db.batch();
    for (const ref of refs.slice(offset, offset + 400)) batch.delete(ref);
    await batch.commit();
  }
}

async function deleteCollection(path) {
  const snap = await db.collection(path).get();
  await commitDeletes(snap.docs.map((doc) => doc.ref));
  return snap.size;
}

async function deleteQuery(query) {
  const snap = await query.get();
  await commitDeletes(snap.docs.map((doc) => doc.ref));
  return snap.size;
}

async function purgePhotoPreviews(eventId) {
  await deleteCollection(`events/${eventId}/photos`);
  try {
    await admin.storage().bucket().deleteFiles({ prefix: `events/${eventId}/photos/` });
  } catch (error) {
    // Firestore metadata is authoritative for access. Storage Rules deny reads
    // when the trusted photo record is gone; physical object cleanup is retried
    // by later retention passes if the provider has a transient failure.
    console.error("Trip preview object cleanup failed", { eventId, error });
  }
}

async function hardDeleteTrip(eventId, event) {
  const membersSnap = await db.collection(`events/${eventId}/members`).get();
  const memberUserIds = membersSnap.docs.map((doc) => doc.id);

  await Promise.all([
    deleteCollection(`events/${eventId}/members`),
    deleteCollection(`events/${eventId}/participants`),
    deleteCollection(`events/${eventId}/photos`),
    deleteCollection(`events/${eventId}/invites`),
  ]);

  const references = memberUserIds.map((uid) => db.doc(`users/${uid}/eventRefs/${eventId}`));
  if (references.length) await commitDeletes(references);

  await Promise.all([
    deleteQuery(db.collectionGroup("pendingInvites").where("eventId", "==", eventId)),
    deleteQuery(db.collectionGroup("notifications").where("eventId", "==", eventId)),
    deleteQuery(db.collection("transfers").where("eventId", "==", eventId)),
  ]);

  const lookupRefs = [];
  if (typeof event.joinCode === "string" && event.joinCode) {
    lookupRefs.push(db.doc(`joinCodes/${event.joinCode}`));
  }
  if (typeof event.inviteToken === "string" && event.inviteToken) {
    lookupRefs.push(db.doc(`inviteTokens/${event.inviteToken}`));
  }
  if (lookupRefs.length) await commitDeletes(lookupRefs);

  try {
    await admin.storage().bucket().deleteFiles({ prefix: `events/${eventId}/` });
  } catch (error) {
    console.error("Deleted Trip storage cleanup failed", { eventId, error });
  }

  await db.doc(`events/${eventId}`).delete();
}

// Face descriptors are no longer directly readable from participant roster
// documents. A signed-in member requests the minimum matching set through this
// trusted callable; it verifies membership before reading private face profiles.
exports.listEventFaceProfiles = onCall(async (request) => {
  const uid = requireAuth(request);
  const eventId = requireString((request.data || {}).eventId, "eventId");

  const [eventSnap, callerMember] = await Promise.all([
    db.doc(`events/${eventId}`).get(),
    db.doc(`events/${eventId}/members/${uid}`).get(),
  ]);
  if (!eventSnap.exists) throw new HttpsError("not-found", "This Trip does not exist.");
  if (!callerMember.exists) throw new HttpsError("permission-denied", "Join this Trip first.");

  const event = eventSnap.data() || {};
  if (event.status !== "active") {
    throw new HttpsError("failed-precondition", "Face matching is available only for an active Trip.");
  }

  const members = await db.collection(`events/${eventId}/members`).get();
  const result = [];
  for (const member of members.docs) {
    const [profileSnap, userSnap] = await Promise.all([
      db.doc(`users/${member.id}/faceProfile/current`).get(),
      db.doc(`users/${member.id}`).get(),
    ]);
    if (!profileSnap.exists) continue;
    const profile = profileSnap.data() || {};
    if (!Array.isArray(profile.embedding) || profile.embedding.length === 0) continue;
    const user = userSnap.exists ? userSnap.data() || {} : {};
    const memberData = member.data() || {};
    result.push({
      userId: member.id,
      displayName: user.displayName || null,
      faceEmbedding: profile.embedding,
      faceTemplates: Array.isArray(profile.templates) ? profile.templates : [],
      faceProfileVersion: Number(profile.version || memberData.faceTemplateVersion || 1),
      joinedAtMillis: memberData.joinedAt instanceof Timestamp ? memberData.joinedAt.toMillis() : Date.now(),
    });
  }

  return { eventId, participants: result };
});

// Defense in depth for legacy and older-client writes: participant documents may
// contain public roster metadata but never biometric descriptors.
exports.scrubParticipantBiometrics = onDocumentWritten(
  "events/{eventId}/participants/{userId}",
  async (event) => {
    const after = event.data && event.data.after;
    if (!after || !after.exists) return;
    const data = after.data() || {};
    const hasBiometrics = Object.prototype.hasOwnProperty.call(data, "faceEmbedding")
      || Object.prototype.hasOwnProperty.call(data, "faceTemplates");
    if (!hasBiometrics) return;
    await after.ref.update({
      faceEmbedding: FieldValue.delete(),
      faceTemplates: FieldValue.delete(),
    });
  }
);

// Deleting a Trip immediately removes photo-match records and preview objects;
// the remaining restorable Trip metadata is then permanently hard-deleted by
// the scheduled seven-day cleanup below.
exports.purgeDeletedTripPreviews = onDocumentWritten(
  "events/{eventId}",
  async (event) => {
    const after = event.data && event.data.after;
    if (!after || !after.exists) return;
    const next = after.data() || {};
    const prior = event.data.before && event.data.before.exists ? event.data.before.data() || {} : {};
    if (next.status !== "deletedByOrganizer" || prior.status === "deletedByOrganizer") return;

    await purgePhotoPreviews(event.params.eventId);
    await after.ref.set({
      deletedAt: Timestamp.now(),
      previewsPurgedAt: Timestamp.now(),
      updatedAt: Timestamp.now(),
    }, { merge: true });
  }
);

// Ended Trip previews exist only for a short recovery/download window. This
// also covers Trips that naturally pass their selected end date without an
// explicit organizer status transition.
exports.purgeExpiredTripPreviews = onSchedule("every 6 hours", async () => {
  const cutoff = Timestamp.fromMillis(Date.now() - PREVIEW_RETENTION_DAYS * DAY_MS);
  const snap = await db.collection("events").where("endsAt", "<=", cutoff).limit(250).get();

  for (const doc of snap.docs) {
    const event = doc.data() || {};
    if (event.previewsPurgedAt instanceof Timestamp) continue;
    await purgePhotoPreviews(doc.id);
    await doc.ref.set({ previewsPurgedAt: Timestamp.now() }, { merge: true });
  }
});

// Deleted Trip cloud data is permanently removed within seven days. The 6.5-day
// threshold leaves operational margin for the hourly scheduler and retries.
exports.hardDeleteDeletedTrips = onSchedule("every 60 minutes", async () => {
  const snap = await db.collection("events")
    .where("status", "==", "deletedByOrganizer")
    .limit(250)
    .get();
  const now = Date.now();

  for (const doc of snap.docs) {
    const event = doc.data() || {};
    const deletedAt = event.deletedAt instanceof Timestamp
      ? event.deletedAt.toMillis()
      : (event.updatedAt instanceof Timestamp ? event.updatedAt.toMillis() : now);
    if (now - deletedAt < DELETED_TRIP_HARD_DELETE_AFTER_MS) continue;
    await hardDeleteTrip(doc.id, event);
  }
});
