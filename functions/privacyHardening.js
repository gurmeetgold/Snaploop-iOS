const { onCall, HttpsError } = require("firebase-functions/https");
const { onDocumentWritten } = require("firebase-functions/v2/firestore");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const admin = require("firebase-admin");

const db = admin.firestore();
const Timestamp = admin.firestore.Timestamp;
const FieldValue = admin.firestore.FieldValue;

const DAY_MS = 24 * 60 * 60 * 1000;
// Cleanup runs hourly. Starting at 14d23h provides scheduling/retry margin so
// Trip-related cloud data is removed within the public 15-day commitment.
const ENDED_TRIP_HARD_DELETE_AFTER_MS = (14 * DAY_MS) + (23 * 60 * 60 * 1000);
const DELETED_TRIP_HARD_DELETE_AFTER_MS = (14 * DAY_MS) + (23 * 60 * 60 * 1000);
const CONSENT_POLICY_VERSION = 2;

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

async function commitUpdates(items) {
  for (let offset = 0; offset < items.length; offset += 400) {
    const batch = db.batch();
    for (const item of items.slice(offset, offset + 400)) batch.update(item.ref, item.data);
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
    console.error("Trip storage cleanup failed", { eventId, error });
  }

  await db.doc(`events/${eventId}`).delete();
}

function callableTemplates(rawTemplates) {
  if (!Array.isArray(rawTemplates)) return [];
  return rawTemplates
    .filter((item) => item && Array.isArray(item.embedding) && item.embedding.length > 0)
    .map((item) => ({
      id: typeof item.id === "string" ? item.id : null,
      embedding: item.embedding,
      pose: typeof item.pose === "string" ? item.pose : "alternate",
      quality: Number(item.quality || 1),
      createdAtMillis: item.createdAt instanceof Timestamp ? item.createdAt.toMillis() : Date.now(),
    }));
}

exports.acceptBiometricConsent = onCall(async (request) => {
  const uid = requireAuth(request);
  const data = request.data || {};
  if (typeof data.userId === "string" && data.userId !== uid) {
    throw new HttpsError("permission-denied", "Consent identity does not match the signed-in user.");
  }
  const requestedVersion = Number(data.policyVersion);
  if (requestedVersion !== CONSENT_POLICY_VERSION) {
    throw new HttpsError("failed-precondition", "Please review the current Face Match Consent before continuing.");
  }

  const acceptedAt = Timestamp.now();
  await db.doc(`users/${uid}/privacy/biometricConsent`).set({
    userId: uid,
    policyVersion: CONSENT_POLICY_VERSION,
    disclosureId: `biometric-consent-v${CONSENT_POLICY_VERSION}`,
    acceptedAt,
    withdrawnAt: null,
  }, { merge: false });

  return {
    accepted: true,
    policyVersion: CONSENT_POLICY_VERSION,
    acceptedAtMillis: acceptedAt.toMillis(),
  };
});

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
      faceTemplates: callableTemplates(profile.templates),
      faceProfileVersion: Number(profile.version || memberData.faceTemplateVersion || 1),
      joinedAtMillis: memberData.joinedAt instanceof Timestamp ? memberData.joinedAt.toMillis() : Date.now(),
    });
  }

  return { eventId, participants: result };
});

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

exports.scrubLegacyParticipantBiometrics = onSchedule("every 24 hours", async () => {
  const snap = await db.collectionGroup("participants").limit(500).get();
  const updates = [];
  for (const doc of snap.docs) {
    const data = doc.data() || {};
    if (
      Object.prototype.hasOwnProperty.call(data, "faceEmbedding")
      || Object.prototype.hasOwnProperty.call(data, "faceTemplates")
    ) {
      updates.push({
        ref: doc.ref,
        data: {
          faceEmbedding: FieldValue.delete(),
          faceTemplates: FieldValue.delete(),
        },
      });
    }
  }
  if (updates.length) await commitUpdates(updates);
});

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

// The selected Trip end time is the retention anchor. Cleanup runs hourly and
// begins at 14d23h so all Trip-related cloud records and Storage objects are
// removed within the public maximum of 15 days after the Trip ends.
exports.purgeExpiredTripPreviews = onSchedule("every 60 minutes", async () => {
  const cutoff = Timestamp.fromMillis(Date.now() - ENDED_TRIP_HARD_DELETE_AFTER_MS);
  const snap = await db.collection("events").where("endsAt", "<=", cutoff).limit(250).get();

  for (const doc of snap.docs) {
    const event = doc.data() || {};
    await hardDeleteTrip(doc.id, event);
  }
});

// Explicitly deleted Trips use the same 15-day maximum retention policy.
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
