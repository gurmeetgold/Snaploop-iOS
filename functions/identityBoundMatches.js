const { onCall, HttpsError } = require("firebase-functions/https");
const { onDocumentWritten } = require("firebase-functions/v2/firestore");
const admin = require("firebase-admin");
const { Timestamp } = require("firebase-admin/firestore");
const { normalizedMembershipId } = require("./membershipIdentity");
const { isWithinEventGraceWindow } = require("./eventDateSemantics");

const db = admin.firestore();

const MAX_APPEARANCES = 50;
const MAX_THUMBNAIL_BYTES = 5 * 1024 * 1024;
const MAX_CLOCK_SKEW_MS = 5 * 60 * 1000;
const EVENT_GRACE_DAYS = 15;
const FACE_PROFILE_VERSION = 5;
const CONSENT_POLICY_VERSION = 5;
const CONSENT_DISCLOSURE_ID = "biometric-consent-v5";
const CONSENT_DISCLOSURE_SHA256 = "2b78a5de4ced7219953cf4c3b62e07dce41392b0090f7c07c3fcb307411bc30f";
const SOURCE_INSTALLATION_ID_PATTERN = /^[0-9a-f]{64}$/i;

function requireAuth(request) {
  if (!request.auth || !request.auth.uid) throw new HttpsError("unauthenticated", "You must be signed in.");
  return request.auth.uid;
}

function requireString(value, name) {
  if (typeof value !== "string" || value.trim().length === 0) throw new HttpsError("invalid-argument", `${name} is required.`);
  return value.trim();
}

function optionalString(value) {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed || null;
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

async function requireCurrentIdentity(uid) {
  const profileSnap = await db.doc(`users/${uid}/faceProfile/current`).get();
  const profile = profileSnap.exists ? profileSnap.data() || {} : null;
  if (!profileIsCurrent(profile)) throw new HttpsError("failed-precondition", "Face Setup is not active.");
  return profileIdentity(profile);
}

function appearanceAllowsViewer(data, uid, currentIdentity, currentMembershipId) {
  const identityMap = data.matchedFaceIdentityIds && typeof data.matchedFaceIdentityIds === "object"
    ? data.matchedFaceIdentityIds
    : {};
  if (identityMap[uid] !== currentIdentity) return false;

  // New matches are bound to the exact uninterrupted Event participation. Old
  // documents without this map remain readable under the legacy identity rule
  // during migration; they do not gain a fabricated membership generation.
  const membershipMap = data.matchedMembershipIds && typeof data.matchedMembershipIds === "object"
    ? data.matchedMembershipIds
    : {};
  const boundMembershipId = normalizedMembershipId(membershipMap[uid]);
  if (boundMembershipId && boundMembershipId !== currentMembershipId) return false;

  const appearances = Array.isArray(data.appearances) ? data.appearances : [];
  return appearances.some((appearance) => {
    if (!appearance || appearance.participantUserId !== uid || appearance.faceIdentityId !== currentIdentity) return false;
    const appearanceMembershipId = normalizedMembershipId(appearance.recipientMembershipId);
    if (appearanceMembershipId && appearanceMembershipId !== currentMembershipId) return false;
    return appearance.dismissedByUser !== true;
  });
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
      const matchedMembershipIds = data.matchedMembershipIds && typeof data.matchedMembershipIds === "object"
        ? { ...data.matchedMembershipIds }
        : {};
      delete matchedFaceIdentityIds[uid];
      delete matchedProfileRevisions[uid];
      delete matchedMembershipIds[uid];
      return {
        ref: doc.ref,
        data: {
          appearances,
          matchedUserIds,
          matchedFaceIdentityIds,
          matchedProfileRevisions,
          matchedMembershipIds,
          updatedAt: Timestamp.now(),
        },
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
  const sourceInstallationId = optionalString(data.sourceInstallationId);
  const suppliedSourceMembershipId = optionalString(data.sourceMembershipId);
  const modernSourceContext = sourceInstallationId !== null;
  const mergeAppearances = data.mergeAppearances === true;

  if (sourceInstallationId && !SOURCE_INSTALLATION_ID_PATTERN.test(sourceInstallationId)) {
    throw new HttpsError("invalid-argument", "Source installation identity is invalid.");
  }
  if (modernSourceContext && !suppliedSourceMembershipId) {
    throw new HttpsError("failed-precondition", "Refresh this Event before sharing photos.");
  }

  const legacyMatchId = `${eventId}:${assetLocalId}`;
  const sourceScopedMatchId = sourceInstallationId
    ? `${eventId}:${sourceInstallationId}:${assetLocalId}`
    : null;
  if (matchId !== legacyMatchId && matchId !== sourceScopedMatchId) {
    throw new HttpsError("invalid-argument", "Photo identity is invalid.");
  }
  if (mergeAppearances && (!modernSourceContext || matchId !== sourceScopedMatchId)) {
    throw new HttpsError("invalid-argument", "Incremental photo updates require a source-scoped photo identity.");
  }

  const capturedAtMillis = requireMillis(data.capturedAtMillis, "capturedAt");
  const matchedAtMillis = requireMillis(data.matchedAtMillis, "matchedAt");
  if (matchedAtMillis > Date.now() + MAX_CLOCK_SKEW_MS) {
    throw new HttpsError("invalid-argument", "Match time is invalid.");
  }

  if (!Array.isArray(data.appearances) || data.appearances.length > MAX_APPEARANCES) {
    throw new HttpsError("invalid-argument", "Appearances are invalid.");
  }

  const seen = new Set();
  const requestedAppearances = data.appearances.map((raw) => {
    const participantUserId = requireString(raw && raw.participantUserId, "participantUserId");
    const confidence = Number(raw && raw.confidence);
    const suppliedIdentity = requireString(raw && raw.faceIdentityId, "faceIdentityId");
    const suppliedRevision = requireString(raw && raw.faceProfileRevision, "faceProfileRevision");
    const suppliedMembershipId = optionalString(raw && raw.recipientMembershipId);
    if (!Number.isFinite(confidence) || confidence < 0 || confidence > 1) {
      throw new HttpsError("invalid-argument", "Appearance confidence is invalid.");
    }
    if (seen.has(participantUserId)) {
      throw new HttpsError("invalid-argument", "Duplicate participant appearance.");
    }
    if (modernSourceContext && !suppliedMembershipId) {
      throw new HttpsError("failed-precondition", "An Event member changed while this photo was being matched. Refresh the Event and scan again.");
    }
    seen.add(participantUserId);
    return {
      participantUserId,
      confidence,
      suppliedIdentity,
      suppliedRevision,
      suppliedMembershipId,
    };
  });

  const docId = photoDocumentId(matchId);
  const thumbnailPath = requireString(data.thumbnailPath, "thumbnailPath");
  if (thumbnailPath !== expectedThumbnailPath(eventId, uid, docId)) {
    throw new HttpsError("invalid-argument", "Thumbnail path is invalid.");
  }

  try {
    const [metadata] = await admin.storage().bucket().file(thumbnailPath).getMetadata();
    const size = Number(metadata.size || 0);
    if (metadata.contentType !== "image/jpeg" || !Number.isFinite(size) || size <= 0 || size > MAX_THUMBNAIL_BYTES) {
      throw new Error("invalid thumbnail metadata");
    }
  } catch (error) {
    console.error("thumbnail verification failed", { eventId, uid, error });
    throw new HttpsError("failed-precondition", "Thumbnail upload could not be verified.");
  }

  const photoRef = db.doc(`events/${eventId}/photos/${docId}`);
  await db.runTransaction(async (tx) => {
    // This is the actual commit barrier. Membership, sharing, Event lifecycle,
    // existing source-photo identity and Face Setup are all re-read
    // transactionally after thumbnail verification.
    const eventRef = db.doc(`events/${eventId}`);
    const sourceMemberRef = db.doc(`events/${eventId}/members/${uid}`);
    const [eventSnap, sourceMemberSnap, existingPhotoSnap] = await Promise.all([
      tx.get(eventRef),
      tx.get(sourceMemberRef),
      tx.get(photoRef),
    ]);

    if (!eventSnap.exists) throw new HttpsError("not-found", "This event does not exist.");
    if (!sourceMemberSnap.exists) throw new HttpsError("permission-denied", "Join this event first.");
    const event = eventSnap.data() || {};
    const sourceMember = sourceMemberSnap.data() || {};
    if (event.status !== "active") throw new HttpsError("failed-precondition", "This event has ended.");
    if (!isWithinEventGraceWindow(event, Date.now(), EVENT_GRACE_DAYS)) {
      throw new HttpsError("failed-precondition", "This event's photo window has expired.");
    }
    if (sourceMember.sharingEnabled === false) {
      throw new HttpsError("failed-precondition", "Photo sharing is turned off for this event.");
    }

    // Canonical v1 Events persist the exact inclusive full-day bounds selected by
    // the organizer, so this transaction verifies the same absolute interval that
    // PhotoKit scanned on iOS. Legacy Events keep their trusted stored timestamps.
    if (!(event.startsAt instanceof Timestamp) || !(event.endsAt instanceof Timestamp)) {
      throw new HttpsError("failed-precondition", "This event has invalid dates.");
    }
    if (capturedAtMillis < event.startsAt.toMillis() || capturedAtMillis > event.endsAt.toMillis()) {
      throw new HttpsError("invalid-argument", "Photo is outside the event date range.");
    }

    const currentSourceMembershipId = normalizedMembershipId(sourceMember.membershipId);
    if (modernSourceContext) {
      if (!currentSourceMembershipId || suppliedSourceMembershipId !== currentSourceMembershipId) {
        throw new HttpsError("failed-precondition", "Your Event membership changed while photos were being scanned. Refresh the Event and scan again.");
      }
    }

    const existingPhoto = existingPhotoSnap.exists ? existingPhotoSnap.data() || {} : null;
    if (mergeAppearances && existingPhoto) {
      const existingCapturedAtMillis = existingPhoto.capturedAt instanceof Timestamp
        ? existingPhoto.capturedAt.toMillis()
        : null;
      if (existingPhoto.eventId !== eventId
          || existingPhoto.sourceUserId !== uid
          || existingPhoto.assetLocalId !== assetLocalId
          || existingPhoto.sourceInstallationId !== sourceInstallationId
          || existingCapturedAtMillis !== capturedAtMillis) {
        throw new HttpsError("failed-precondition", "Existing source photo identity does not match this scan.");
      }
    }

    const appearanceByUser = new Map();
    const matchedFaceIdentityIds = mergeAppearances && existingPhoto
      && existingPhoto.matchedFaceIdentityIds && typeof existingPhoto.matchedFaceIdentityIds === "object"
      ? { ...existingPhoto.matchedFaceIdentityIds }
      : {};
    const matchedProfileRevisions = mergeAppearances && existingPhoto
      && existingPhoto.matchedProfileRevisions && typeof existingPhoto.matchedProfileRevisions === "object"
      ? { ...existingPhoto.matchedProfileRevisions }
      : {};
    const matchedMembershipIds = mergeAppearances && existingPhoto
      && existingPhoto.matchedMembershipIds && typeof existingPhoto.matchedMembershipIds === "object"
      ? { ...existingPhoto.matchedMembershipIds }
      : {};

    if (mergeAppearances && existingPhoto && Array.isArray(existingPhoto.appearances)) {
      for (const appearance of existingPhoto.appearances) {
        if (!appearance || typeof appearance.participantUserId !== "string") continue;
        appearanceByUser.set(appearance.participantUserId, appearance);
      }
    }

    for (const requested of requestedAppearances) {
      const memberRef = db.doc(`events/${eventId}/members/${requested.participantUserId}`);
      const profileRef = db.doc(`users/${requested.participantUserId}/faceProfile/current`);
      const [memberSnap, profileSnap] = await Promise.all([
        tx.get(memberRef),
        tx.get(profileRef),
      ]);

      if (!memberSnap.exists) {
        throw new HttpsError("failed-precondition", "An Event member changed while this photo was being matched. Refresh the Event and scan again.");
      }
      const member = memberSnap.data() || {};
      const currentMembershipId = normalizedMembershipId(member.membershipId);
      if (requested.suppliedMembershipId) {
        if (!currentMembershipId || requested.suppliedMembershipId !== currentMembershipId) {
          throw new HttpsError("failed-precondition", "An Event member changed while this photo was being matched. Refresh the Event and scan again.");
        }
      } else if (modernSourceContext) {
        throw new HttpsError("failed-precondition", "Refresh this Event before sharing photos.");
      }

      const profile = profileSnap.exists ? profileSnap.data() || {} : null;
      if (!profileIsCurrent(profile)) {
        throw new HttpsError("failed-precondition", "A matched person's Face Setup is no longer active. Refresh the Event and scan again.");
      }

      const currentIdentity = profileIdentity(profile);
      const currentRevision = profileRevision(profile);
      if (requested.suppliedIdentity !== currentIdentity || requested.suppliedRevision !== currentRevision) {
        throw new HttpsError("failed-precondition", "A Face Setup changed while this photo was being matched. Refresh the Event and scan again.");
      }

      const appearance = {
        participantUserId: requested.participantUserId,
        confidence: requested.confidence,
        faceIdentityId: currentIdentity,
        faceProfileRevision: currentRevision,
        dismissedByUser: false,
      };
      if (requested.suppliedMembershipId) {
        appearance.recipientMembershipId = requested.suppliedMembershipId;
        matchedMembershipIds[requested.participantUserId] = requested.suppliedMembershipId;
      }
      appearanceByUser.set(requested.participantUserId, appearance);
      matchedFaceIdentityIds[requested.participantUserId] = currentIdentity;
      matchedProfileRevisions[requested.participantUserId] = currentRevision;
    }

    const appearances = [...appearanceByUser.values()];
    if (appearances.length > MAX_APPEARANCES) {
      throw new HttpsError("resource-exhausted", "This photo has too many Event appearances.");
    }

    const now = Timestamp.now();
    const document = {
      id: matchId,
      eventId,
      sourceUserId: uid,
      assetLocalId,
      appearances,
      matchedUserIds: appearances.map((appearance) => appearance.participantUserId),
      matchedFaceIdentityIds,
      matchedProfileRevisions,
      matchedMembershipIds,
      capturedAt: Timestamp.fromMillis(capturedAtMillis),
      matchedAt: Timestamp.fromMillis(matchedAtMillis),
      thumbnailPath,
      createdAt: mergeAppearances && existingPhoto && existingPhoto.createdAt instanceof Timestamp
        ? existingPhoto.createdAt
        : now,
      updatedAt: now,
    };
    if (sourceInstallationId) document.sourceInstallationId = sourceInstallationId;
    if (modernSourceContext) document.sourceMembershipId = suppliedSourceMembershipId;

    tx.set(photoRef, document, { merge: false });
  });

  return { eventId, photoId: docId };
});

exports.listMyMatchedPhotosIdentityBound = onCall(async (request) => {
  const uid = requireAuth(request);
  const eventId = requireString((request.data || {}).eventId, "eventId");
  const member = await requireMember(eventId, uid);
  const currentMembershipId = normalizedMembershipId(member.membershipId);

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
    if (!appearanceAllowsViewer(data, uid, currentIdentity, currentMembershipId)) continue;

    result.push({
      id: data.id || "",
      eventId: data.eventId || eventId,
      sourceUserId: data.sourceUserId || "",
      sourceInstallationId: typeof data.sourceInstallationId === "string" ? data.sourceInstallationId : null,
      sourceMembershipId: typeof data.sourceMembershipId === "string" ? data.sourceMembershipId : null,
      assetLocalId: data.assetLocalId || "",
      appearances: Array.isArray(data.appearances) ? data.appearances : [],
      matchedMembershipIds: data.matchedMembershipIds && typeof data.matchedMembershipIds === "object"
        ? data.matchedMembershipIds
        : {},
      capturedAtMillis: data.capturedAt instanceof Timestamp ? data.capturedAt.toMillis() : null,
      matchedAtMillis: data.matchedAt instanceof Timestamp ? data.matchedAt.toMillis() : null,
      thumbnailPath: typeof data.thumbnailPath === "string" ? data.thumbnailPath : null,
    });
  }

  // During the one-time Change-4 transition, a legacy event:user:asset document
  // can coexist with the new source-scoped document for the same physical source
  // photo. Prefer the modern row in that exact equivalence class, but never
  // collapse two modern installation IDs from the same account.
  const equivalenceKey = (row) => [
    row.sourceUserId || "",
    row.assetLocalId || "",
    String(row.capturedAtMillis || ""),
  ].join("\u0000");
  const modernKeys = new Set(
    result.filter((row) => row.sourceInstallationId).map(equivalenceKey)
  );
  const deduped = result.filter((row) =>
    row.sourceInstallationId || !modernKeys.has(equivalenceKey(row))
  );

  deduped.sort((a, b) => Number(b.capturedAtMillis || 0) - Number(a.capturedAtMillis || 0));
  return { eventId, photos: deduped };
});

// Secure fallback for clients whose direct Firebase Storage read fails after the
// match itself has already passed identity authorization. The callable repeats
// the same membership-generation + stable-identity checks, then returns only
// that one optimized JPEG preview. Candidate faces and originals are never
// exposed.
exports.getMatchedThumbnailIdentityBound = onCall(async (request) => {
  const uid = requireAuth(request);
  const data = request.data || {};
  const eventId = requireString(data.eventId, "eventId");
  const photoId = requireString(data.photoId, "photoId");
  const member = await requireMember(eventId, uid);
  const currentMembershipId = normalizedMembershipId(member.membershipId);
  const currentIdentity = await requireCurrentIdentity(uid);

  const photoSnap = await db.doc(`events/${eventId}/photos/${photoId}`).get();
  if (!photoSnap.exists) throw new HttpsError("not-found", "This matched photo is no longer available.");
  const photo = photoSnap.data() || {};
  if (!appearanceAllowsViewer(photo, uid, currentIdentity, currentMembershipId)) {
    throw new HttpsError("permission-denied", "This photo is not available to your current Event participation and Face Setup.");
  }

  const sourceUserId = requireString(photo.sourceUserId, "sourceUserId");
  const thumbnailPath = requireString(photo.thumbnailPath, "thumbnailPath");
  if (thumbnailPath !== expectedThumbnailPath(eventId, sourceUserId, photoId)) {
    throw new HttpsError("failed-precondition", "Matched photo storage metadata is invalid.");
  }

  try {
    const [buffer] = await admin.storage().bucket().file(thumbnailPath).download();
    if (!buffer || buffer.length <= 0 || buffer.length > MAX_THUMBNAIL_BYTES) {
      throw new Error("invalid thumbnail size");
    }
    return { contentType: "image/jpeg", base64: buffer.toString("base64") };
  } catch (error) {
    console.error("authorized thumbnail fallback failed", { eventId, uid, error });
    throw new HttpsError("unavailable", "This photo preview could not be loaded right now.");
  }
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
    console.log("Face identity changed; old face-derived matches scrubbed", { scrubbedPhotos });
    return;
  }

  if (beforeIdentity && beforeIdentity === afterIdentity && beforeRevision !== afterRevision) {
    console.log("Face Setup refreshed for the same identity; existing positive matches preserved");
  }
});
