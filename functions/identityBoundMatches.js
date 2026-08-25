const { onCall, HttpsError } = require("firebase-functions/https");
const { onDocumentWritten } = require("firebase-functions/v2/firestore");
const admin = require("firebase-admin");

const db = admin.firestore();
const Timestamp = admin.firestore.Timestamp;

const MAX_APPEARANCES = 50;
const MAX_THUMBNAIL_BYTES = 5 * 1024 * 1024;
const MAX_CLOCK_SKEW_MS = 5 * 60 * 1000;
const FACE_PROFILE_VERSION = 5;
const CONSENT_POLICY_VERSION = 5;
const CONSENT_DISCLOSURE_ID = "biometric-consent-v5";
const CONSENT_DISCLOSURE_SHA256 = "2b78a5de4ced7219953cf4c3b62e07dce41392b0090f7c07c3fcb307411bc30f";

function requireAuth(request) {
  if (!request.auth || !request.auth.uid) throw new HttpsError("unauthenticated", "You must be signed in.");
  return request.auth.uid;
}

function requireString(value, name) {
  if (typeof value !== "string" || value.trim().length === 0) throw new HttpsError("invalid-argument", `${name} is required.`);
  return value.trim();
}

function requireMillis(value, name) {
  const n = Number(value);
  if (!Number.isFinite(n)) throw new HttpsError("invalid-argument", `${name} is invalid.`);
  return n;
}

function photoDocumentId(matchId) {
  return Buffer.from(matchId, "utf8").toString("base64url");
}

function expectedThumbnailPath(eventId, uid, docId) {
  return `events/${eventId}/photos/${uid}/${docId}/thumbnail.jpg`;
}

function profileRevision(profile) {
  if (!profile || typeof profile !== "object") return null;
  const version = Number(profile.version || 0);
  const templates = Array.isArray(profile.templates) ? profile.templates : [];
  const ids = templates
    .map((item) => item && typeof item.id === "string" ? item.id.trim() : "")
    .filter(Boolean)
    .sort();
  return version > 0 && ids.length ? `v${version}:${ids.join("|")}` : null;
}

function profileIdentity(profile) {
  return profile && typeof profile.faceIdentityId === "string" ? profile.faceIdentityId.trim() : "";
}

function profileIsCurrent(profile) {
  return !!profile
    && Number(profile.version) === FACE_PROFILE_VERSION
    && Number(profile.consentPolicyVersion) === CONSENT_POLICY_VERSION
    && profile.consentDisclosureId === CONSENT_DISCLOSURE_ID
    && profile.consentDisclosureSHA256 === CONSENT_DISCLOSURE_SHA256
    && profile.expiresAt instanceof Timestamp
    && profile.expiresAt.toMillis() > Date.now()
    && !!profileRevision(profile)
    && !!profileIdentity(profile);
}

async function requireMember(eventId, uid) {
  const snap = await db.doc(`events/${eventId}/members/${uid}`).get();
  if (!snap.exists) throw new HttpsError("permission-denied", "Join this event first.");
  return snap.data() || {};
}

async function commitUpdates(items) {
  for (let offset = 0; offset < items.length; offset += 400) {
    const batch = db.batch();
    for (const item of items.slice(offset, offset + 400)) batch.update(item.ref, item.data);
    await batch.commit();
  }
}

async function scrubUserFromAllEventMatches(uid) {
  const eventRefs = await db.collection(`users/${uid}/eventRefs`).get();
  let scrubbed = 0;

  for (const eventRef of eventRefs.docs) {
    const eventId = eventRef.id;
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
      delete matchedFaceIdentityIds[uid];
      delete matchedProfileRevisions[uid];
      return {
        ref: doc.ref,
        data: { appearances, matchedUserIds, matchedFaceIdentityIds, matchedProfileRevisions, updatedAt: Timestamp.now() },
      };
    });

    if (updates.length) {
      await commitUpdates(updates);
      scrubbed += updates.length;
    }
  }

  return scrubbed;
}

exports.publishMatchIdentityBound = onCall(async (request) => {
  const uid = requireAuth(request);
  const data = request.data || {};
  const eventId = requireString(data.eventId, "eventId");
  const assetLocalId = requireString(data.assetLocalId, "assetLocalId");
  const matchId = requireString(data.id, "id");
  if (matchId !== `${eventId}:${assetLocalId}`) throw new HttpsError("invalid-argument", "Photo identity is invalid.");

  const sourceMember = await requireMember(eventId, uid);
  if (sourceMember.sharingEnabled === false) throw new HttpsError("failed-precondition", "Photo sharing is turned off for this event.");

  const eventSnap = await db.doc(`events/${eventId}`).get();
  if (!eventSnap.exists) throw new HttpsError("not-found", "This event does not exist.");
  const event = eventSnap.data() || {};
  if (event.status !== "active") throw new HttpsError("failed-precondition", "This event has ended.");

  const capturedAtMillis = requireMillis(data.capturedAtMillis, "capturedAt");
  const matchedAtMillis = requireMillis(data.matchedAtMillis, "matchedAt");
  if (matchedAtMillis > Date.now() + MAX_CLOCK_SKEW_MS) throw new HttpsError("invalid-argument", "Match time is invalid.");
  if (event.startsAt instanceof Timestamp && capturedAtMillis < event.startsAt.toMillis()) throw new HttpsError("invalid-argument", "Photo is outside the event date range.");
  if (event.endsAt instanceof Timestamp && capturedAtMillis > event.endsAt.toMillis()) throw new HttpsError("invalid-argument", "Photo is outside the event date range.");

  if (!Array.isArray(data.appearances) || data.appearances.length > MAX_APPEARANCES) throw new HttpsError("invalid-argument", "Appearances are invalid.");

  const seen = new Set();
  const appearances = [];
  const matchedFaceIdentityIds = {};
  const matchedProfileRevisions = {};

  for (const raw of data.appearances) {
    const participantUserId = requireString(raw && raw.participantUserId, "participantUserId");
    const confidence = Number(raw && raw.confidence);
    const suppliedIdentity = requireString(raw && raw.faceIdentityId, "faceIdentityId");
    const suppliedRevision = requireString(raw && raw.faceProfileRevision, "faceProfileRevision");
    if (!Number.isFinite(confidence) || confidence < 0 || confidence > 1) throw new HttpsError("invalid-argument", "Appearance confidence is invalid.");
    if (seen.has(participantUserId)) throw new HttpsError("invalid-argument", "Duplicate participant appearance.");
    seen.add(participantUserId);

    const [memberSnap, profileSnap] = await Promise.all([
      db.doc(`events/${eventId}/members/${participantUserId}`).get(),
      db.doc(`users/${participantUserId}/faceProfile/current`).get(),
    ]);
    if (!memberSnap.exists) throw new HttpsError("invalid-argument", "A matched person is not a member of this event.");
    const profile = profileSnap.exists ? profileSnap.data() || {} : null;
    if (!profileIsCurrent(profile)) throw new HttpsError("failed-precondition", "A matched person's Face Setup is no longer active. Refresh the Event and scan again.");

    const currentIdentity = profileIdentity(profile);
    const currentRevision = profileRevision(profile);
    if (suppliedIdentity !== currentIdentity || suppliedRevision !== currentRevision) {
      throw new HttpsError("failed-precondition", "A Face Setup changed while this photo was being matched. Refresh the Event and scan again.");
    }

    appearances.push({
      participantUserId,
      confidence,
      faceIdentityId: currentIdentity,
      faceProfileRevision: currentRevision,
      dismissedByUser: false,
    });
    matchedFaceIdentityIds[participantUserId] = currentIdentity;
    matchedProfileRevisions[participantUserId] = currentRevision;
  }

  const docId = photoDocumentId(matchId);
  const thumbnailPath = requireString(data.thumbnailPath, "thumbnailPath");
  if (thumbnailPath !== expectedThumbnailPath(eventId, uid, docId)) throw new HttpsError("invalid-argument", "Thumbnail path is invalid.");

  try {
    const [metadata] = await admin.storage().bucket().file(thumbnailPath).getMetadata();
    const size = Number(metadata.size || 0);
    if (metadata.contentType !== "image/jpeg" || !Number.isFinite(size) || size <= 0 || size > MAX_THUMBNAIL_BYTES) throw new Error("invalid thumbnail metadata");
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
    matchedFaceIdentityIds,
    matchedProfileRevisions,
    capturedAt: Timestamp.fromMillis(capturedAtMillis),
    matchedAt: Timestamp.fromMillis(matchedAtMillis),
    thumbnailPath,
    createdAt: Timestamp.now(),
    updatedAt: Timestamp.now(),
  }, { merge: false });

  return { eventId, photoId: docId };
});

exports.listMyMatchedPhotosIdentityBound = onCall(async (request) => {
  const uid = requireAuth(request);
  const eventId = requireString((request.data || {}).eventId, "eventId");
  await requireMember(eventId, uid);

  const profileSnap = await db.doc(`users/${uid}/faceProfile/current`).get();
  const profile = profileSnap.exists ? profileSnap.data() || {} : null;
  if (!profileIsCurrent(profile)) return { eventId, photos: [] };
  const currentIdentity = profileIdentity(profile);

  const snap = await db.collection(`events/${eventId}/photos`)
    .where("matchedUserIds", "array-contains", uid)
    .get();

  const result = [];
  for (const doc of snap.docs) {
    const data = doc.data() || {};
    const identityMap = data.matchedFaceIdentityIds && typeof data.matchedFaceIdentityIds === "object"
      ? data.matchedFaceIdentityIds
      : {};
    if (identityMap[uid] !== currentIdentity) continue;
    const appearances = Array.isArray(data.appearances) ? data.appearances : [];
    const currentAppearance = appearances.find((appearance) =>
      appearance && appearance.participantUserId === uid
        && appearance.faceIdentityId === currentIdentity
        && appearance.dismissedByUser !== true
    );
    if (!currentAppearance) continue;

    result.push({
      id: data.id || "",
      eventId: data.eventId || eventId,
      sourceUserId: data.sourceUserId || "",
      assetLocalId: data.assetLocalId || "",
      appearances,
      capturedAtMillis: data.capturedAt instanceof Timestamp ? data.capturedAt.toMillis() : null,
      matchedAtMillis: data.matchedAt instanceof Timestamp ? data.matchedAt.toMillis() : null,
      thumbnailPath: typeof data.thumbnailPath === "string" ? data.thumbnailPath : null,
    });
  }

  result.sort((a, b) => Number(b.capturedAtMillis || 0) - Number(a.capturedAtMillis || 0));
  return { eventId, photos: result };
});

exports.scrubMatchesOnFaceProfileChange = onDocumentWritten("users/{userId}/faceProfile/current", async (event) => {
  const uid = event.params.userId;
  const before = event.data && event.data.before && event.data.before.exists ? event.data.before.data() || {} : null;
  const after = event.data && event.data.after && event.data.after.exists ? event.data.after.data() || {} : null;
  const beforeIdentity = profileIdentity(before);
  const afterIdentity = profileIdentity(after);
  const beforeRevision = profileRevision(before);
  const afterRevision = profileRevision(after);

  if (beforeIdentity && beforeIdentity !== afterIdentity) {
    const scrubbedPhotos = await scrubUserFromAllEventMatches(uid);
    console.log("Face identity changed; old face-derived matches scrubbed", { uid, scrubbedPhotos });
    return;
  }

  if (beforeIdentity && beforeIdentity === afterIdentity && beforeRevision !== afterRevision) {
    console.log("Face Setup refreshed for the same identity; existing positive matches preserved", { uid });
  }
});
