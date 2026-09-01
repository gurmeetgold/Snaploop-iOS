const { onCall, HttpsError } = require("firebase-functions/https");
const admin = require("firebase-admin");
const { Timestamp } = require("firebase-admin/firestore");
const { normalizedMembershipId } = require("./membershipIdentity");
const { isWithinEventGraceWindow } = require("./eventDateSemantics");
const {
  finalizeIncrementalMatchState,
  prepareIncrementalMatchState,
  recipientDismissalApplies,
  removeActiveAppearance,
  upsertActiveAppearance,
} = require("./change4MatchMetadata");

const db = admin.firestore();

const MAX_APPEARANCES = 50;
const MAX_RECIPIENT_REMOVALS = 50;
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
  if (typeof value !== "string" || value.trim().length === 0) {
    throw new HttpsError("invalid-argument", `${name} is required.`);
  }
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

async function validateCurrentRecipient(tx, eventId, requested, modernSourceContext) {
  const memberRef = db.doc(`events/${eventId}/members/${requested.participantUserId}`);
  const profileRef = db.doc(`users/${requested.participantUserId}/faceProfile/current`);
  const [memberSnap, profileSnap] = await Promise.all([
    tx.get(memberRef),
    tx.get(profileRef),
  ]);

  if (!memberSnap.exists) {
    throw new HttpsError(
      "failed-precondition",
      "An Event member changed while this photo was being matched. Refresh the Event and scan again."
    );
  }
  const member = memberSnap.data() || {};
  const currentMembershipId = normalizedMembershipId(member.membershipId);
  if (requested.suppliedMembershipId) {
    if (!currentMembershipId || requested.suppliedMembershipId !== currentMembershipId) {
      throw new HttpsError(
        "failed-precondition",
        "An Event member changed while this photo was being matched. Refresh the Event and scan again."
      );
    }
  } else if (modernSourceContext) {
    throw new HttpsError("failed-precondition", "Refresh this Event before sharing photos.");
  }

  const profile = profileSnap.exists ? profileSnap.data() || {} : null;
  if (!profileIsCurrent(profile)) {
    throw new HttpsError(
      "failed-precondition",
      "A matched person's Face Setup is no longer active. Refresh the Event and scan again."
    );
  }

  const currentIdentity = profileIdentity(profile);
  const currentRevision = profileRevision(profile);
  if (requested.suppliedIdentity !== currentIdentity || requested.suppliedRevision !== currentRevision) {
    throw new HttpsError(
      "failed-precondition",
      "A Face Setup changed while this photo was being matched. Refresh the Event and scan again."
    );
  }

  return { currentMembershipId, currentIdentity, currentRevision };
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
  const metadataOnly = data.metadataOnly === true;

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
      throw new HttpsError(
        "failed-precondition",
        "An Event member changed while this photo was being matched. Refresh the Event and scan again."
      );
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

  const rawRemovals = data.recipientRemovals === undefined ? [] : data.recipientRemovals;
  if (!Array.isArray(rawRemovals) || rawRemovals.length > MAX_RECIPIENT_REMOVALS) {
    throw new HttpsError("invalid-argument", "Recipient removals are invalid.");
  }
  if (rawRemovals.length > 0 && (!modernSourceContext || !mergeAppearances)) {
    throw new HttpsError("invalid-argument", "Recipient removals require an incremental source-scoped photo.");
  }

  const removalSeen = new Set();
  const requestedRemovals = rawRemovals.map((raw) => {
    const participantUserId = requireString(raw && raw.participantUserId, "participantUserId");
    const suppliedIdentity = requireString(raw && raw.faceIdentityId, "faceIdentityId");
    const suppliedRevision = requireString(raw && raw.faceProfileRevision, "faceProfileRevision");
    const suppliedMembershipId = optionalString(raw && raw.recipientMembershipId);
    if (seen.has(participantUserId) || removalSeen.has(participantUserId)) {
      throw new HttpsError("invalid-argument", "A recipient cannot be both added and removed in one photo update.");
    }
    if (modernSourceContext && !suppliedMembershipId) {
      throw new HttpsError(
        "failed-precondition",
        "An Event member changed while this photo was being matched. Refresh the Event and scan again."
      );
    }
    removalSeen.add(participantUserId);
    return {
      participantUserId,
      suppliedIdentity,
      suppliedRevision,
      suppliedMembershipId,
    };
  });

  if (metadataOnly && (
    !modernSourceContext
    || !mergeAppearances
    || requestedAppearances.length !== 0
    || requestedRemovals.length === 0
  )) {
    throw new HttpsError("invalid-argument", "Metadata-only reconciliation is invalid.");
  }

  const docId = photoDocumentId(matchId);
  const thumbnailPath = requireString(data.thumbnailPath, "thumbnailPath");
  if (thumbnailPath !== expectedThumbnailPath(eventId, uid, docId)) {
    throw new HttpsError("invalid-argument", "Thumbnail path is invalid.");
  }

  if (!metadataOnly) {
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
  }

  const photoRef = db.doc(`events/${eventId}/photos/${docId}`);
  await db.runTransaction(async (tx) => {
    // Final authorization/identity commit barrier. Everything that can change
    // while local matching or thumbnail upload is in flight is re-read here.
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

    if (!(event.startsAt instanceof Timestamp) || !(event.endsAt instanceof Timestamp)) {
      throw new HttpsError("failed-precondition", "This event has invalid dates.");
    }
    if (capturedAtMillis < event.startsAt.toMillis() || capturedAtMillis > event.endsAt.toMillis()) {
      throw new HttpsError("invalid-argument", "Photo is outside the event date range.");
    }

    const currentSourceMembershipId = normalizedMembershipId(sourceMember.membershipId);
    if (modernSourceContext
        && (!currentSourceMembershipId || suppliedSourceMembershipId !== currentSourceMembershipId)) {
      throw new HttpsError(
        "failed-precondition",
        "Your Event membership changed while photos were being scanned. Refresh the Event and scan again."
      );
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

    // Never carry recipient authorization across a source leave/rejoin. A fast
    // rejoin can race asynchronous member cleanup, so an old-generation document
    // is either replaced by a fresh positive publication or ignored by a
    // removal-only reconciliation. In both cases it cannot authorize the new
    // participation accidentally.
    const existingSourceMembershipId = existingPhoto
      ? normalizedMembershipId(existingPhoto.sourceMembershipId)
      : null;
    const canMergeExistingGeneration = mergeAppearances
      && existingPhoto
      && (!modernSourceContext || existingSourceMembershipId === suppliedSourceMembershipId);

    if (metadataOnly && !canMergeExistingGeneration) {
      // Nothing from the current source generation exists to revoke. This is a
      // successful no-op; it can happen if leave/sharing cleanup won the race.
      return;
    }

    const mergeBase = canMergeExistingGeneration ? existingPhoto : null;
    const state = prepareIncrementalMatchState(mergeBase);

    for (const requested of requestedAppearances) {
      // Dismissals created by modern clients are bound to a membership
      // generation. A later participation may be evaluated again; a dismissal
      // from the current participation can never be resurrected by this source.
      if (recipientDismissalApplies(
        state,
        requested.participantUserId,
        requested.suppliedMembershipId
      )) continue;

      const current = await validateCurrentRecipient(tx, eventId, requested, modernSourceContext);
      upsertActiveAppearance(state, {
        participantUserId: requested.participantUserId,
        confidence: requested.confidence,
        faceIdentityId: current.currentIdentity,
        faceProfileRevision: current.currentRevision,
        recipientMembershipId: requested.suppliedMembershipId,
      });
    }

    for (const requested of requestedRemovals) {
      // A stale negative must be unable to revoke a match created under a newer
      // membership or Face Setup revision. Re-read and compare all three pieces
      // of recipient identity at the same transaction commit barrier.
      await validateCurrentRecipient(tx, eventId, requested, modernSourceContext);
      removeActiveAppearance(state, requested.participantUserId);
    }

    const finalized = finalizeIncrementalMatchState(state);
    if (finalized.appearances.length > MAX_APPEARANCES) {
      throw new HttpsError("resource-exhausted", "This photo has too many Event appearances.");
    }

    const now = Timestamp.now();
    const document = {
      id: matchId,
      eventId,
      sourceUserId: uid,
      assetLocalId,
      appearances: finalized.appearances,
      matchedUserIds: finalized.matchedUserIds,
      matchedFaceIdentityIds: finalized.matchedFaceIdentityIds,
      matchedProfileRevisions: finalized.matchedProfileRevisions,
      matchedMembershipIds: finalized.matchedMembershipIds,
      dismissedUserIds: finalized.dismissedUserIds,
      dismissedMembershipIds: finalized.dismissedMembershipIds,
      capturedAt: Timestamp.fromMillis(capturedAtMillis),
      matchedAt: Timestamp.fromMillis(matchedAtMillis),
      thumbnailPath: metadataOnly && existingPhoto && typeof existingPhoto.thumbnailPath === "string"
        ? existingPhoto.thumbnailPath
        : thumbnailPath,
      createdAt: canMergeExistingGeneration && existingPhoto.createdAt instanceof Timestamp
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
