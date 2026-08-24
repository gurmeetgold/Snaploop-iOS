const { onCall, HttpsError } = require("firebase-functions/https");
const { onDocumentWritten } = require("firebase-functions/v2/firestore");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const admin = require("firebase-admin");

const db = admin.firestore();
const Timestamp = admin.firestore.Timestamp;
const FieldValue = admin.firestore.FieldValue;

const DAY_MS = 24 * 60 * 60 * 1000;
const FIFTEEN_DAY_CLEANUP_AFTER_MS = (14 * DAY_MS) + (23 * 60 * 60 * 1000);
const BIOMETRIC_INACTIVITY_MS = 365 * DAY_MS;
const CONSENT_POLICY_VERSION = 4;
const CONSENT_DISCLOSURE_ID = "biometric-consent-v4";
const CONSENT_DISCLOSURE_SHA256 = "3d64afbedd5cd859e1594d77c5d928eda779a6067a48c1cff3d8d401b276fd90";
const CONSENT_METHOD = "explicit-button";
const FACE_PROFILE_VERSION = 5;
const FACE_EMBEDDING_DIMENSION = 512;
const MAX_FACE_TEMPLATES = 5;
const MIN_FACE_TEMPLATES = 3;
const VALID_POSES = new Set(["center", "sideA", "sideB", "tilted", "alternate", "imported"]);
const CANADIAN_SUBDIVISIONS = new Set(["AB", "BC", "MB", "NB", "NL", "NS", "NT", "NU", "ON", "PE", "QC", "SK", "YT"]);
const US_SUBDIVISIONS = new Set([
  "AL", "AK", "AZ", "AR", "CA", "CO", "CT", "DE", "DC", "FL", "GA", "HI", "ID", "IL", "IN", "IA",
  "KS", "KY", "LA", "ME", "MD", "MA", "MI", "MN", "MS", "MO", "MT", "NE", "NV", "NH", "NJ", "NM",
  "NY", "NC", "ND", "OH", "OK", "OR", "PA", "RI", "SC", "SD", "TN", "TX", "UT", "VT", "VA", "WA",
  "WV", "WI", "WY", "AS", "GU", "MP", "PR", "VI"
]);

function requireAuth(request) {
  if (!request.auth || !request.auth.uid) throw new HttpsError("unauthenticated", "You must be signed in.");
  return request.auth.uid;
}
function requireString(value, name) {
  if (typeof value !== "string" || !value.trim()) throw new HttpsError("invalid-argument", `${name} is required.`);
  return value.trim();
}
function boundedString(value, name, maxLength) {
  const string = requireString(value, name);
  if (string.length > maxLength) throw new HttpsError("invalid-argument", `${name} is too long.`);
  return string;
}
function normalizeCode(value, name) {
  return boundedString(value, name, 8).toUpperCase();
}
function jurisdictionIsSupported(country, subdivision) {
  if (country === "CA") return CANADIAN_SUBDIVISIONS.has(subdivision) && subdivision !== "QC";
  if (country === "US") return US_SUBDIVISIONS.has(subdivision) && subdivision !== "IL";
  return false;
}
function jurisdictionUnavailableMessage(country, subdivision) {
  if (country === "CA" && subdivision === "QC") return "Face Match is not currently available to users who ordinarily reside in Quebec.";
  if (country === "US" && subdivision === "IL") return "Face Match is not currently available to users who ordinarily reside in Illinois.";
  return "Face Match is not currently available in the selected jurisdiction.";
}
function consentIsActive(consent) {
  if (!consent) return false;
  const country = typeof consent.jurisdictionCountry === "string" ? consent.jurisdictionCountry.toUpperCase() : "";
  const subdivision = typeof consent.jurisdictionSubdivision === "string" ? consent.jurisdictionSubdivision.toUpperCase() : "";
  return Number(consent.policyVersion) === CONSENT_POLICY_VERSION
    && consent.disclosureId === CONSENT_DISCLOSURE_ID
    && consent.disclosureSHA256 === CONSENT_DISCLOSURE_SHA256
    && consent.withdrawnAt == null
    && consent.expiredAt == null
    && jurisdictionIsSupported(country, subdivision);
}
function requireEmbedding(raw, name) {
  if (!Array.isArray(raw) || raw.length !== FACE_EMBEDDING_DIMENSION) {
    throw new HttpsError("invalid-argument", `${name} must be a ${FACE_EMBEDDING_DIMENSION}-dimension embedding.`);
  }
  const vector = raw.map(Number);
  if (vector.some((value) => !Number.isFinite(value))) {
    throw new HttpsError("invalid-argument", `${name} contains invalid values.`);
  }
  const norm = Math.sqrt(vector.reduce((sum, value) => sum + (value * value), 0));
  if (!Number.isFinite(norm) || norm < 0.90 || norm > 1.10) {
    throw new HttpsError("invalid-argument", `${name} is not a normalized embedding.`);
  }
  return vector;
}
function requireTemplates(rawTemplates, now) {
  if (!Array.isArray(rawTemplates) || rawTemplates.length < MIN_FACE_TEMPLATES || rawTemplates.length > MAX_FACE_TEMPLATES) {
    throw new HttpsError("invalid-argument", `Face Setup must contain ${MIN_FACE_TEMPLATES}-${MAX_FACE_TEMPLATES} enrollment templates.`);
  }
  return rawTemplates.map((item, index) => {
    if (!item || typeof item !== "object") throw new HttpsError("invalid-argument", "Face template is invalid.");
    const embedding = requireEmbedding(item.embedding, `templates[${index}].embedding`);
    const pose = requireString(item.pose, `templates[${index}].pose`);
    if (!VALID_POSES.has(pose)) throw new HttpsError("invalid-argument", "Face template pose is invalid.");
    const quality = Number(item.quality);
    if (!Number.isFinite(quality) || quality < 0 || quality > 1) throw new HttpsError("invalid-argument", "Face template quality is invalid.");
    const requestedCreatedAt = Number(item.createdAtMillis);
    const createdAtMillis = Number.isFinite(requestedCreatedAt)
      ? Math.min(now.toMillis(), Math.max(0, requestedCreatedAt))
      : now.toMillis();
    return {
      id: typeof item.id === "string" && item.id.length <= 128 ? item.id : null,
      embedding,
      pose,
      quality,
      createdAt: Timestamp.fromMillis(createdAtMillis),
    };
  });
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
}
async function deleteQuery(query) {
  const snap = await query.get();
  await commitDeletes(snap.docs.map((doc) => doc.ref));
}
async function scrubUserFromEventPhotos(eventId, uid) {
  const snap = await db.collection(`events/${eventId}/photos`).where("matchedUserIds", "array-contains", uid).get();
  const updates = [];
  for (const doc of snap.docs) {
    const data = doc.data() || {};
    const appearances = Array.isArray(data.appearances)
      ? data.appearances.filter((appearance) => appearance.participantUserId !== uid)
      : [];
    const matchedUserIds = Array.isArray(data.matchedUserIds)
      ? data.matchedUserIds.filter((userId) => userId !== uid)
      : [];
    updates.push({ ref: doc.ref, data: { appearances, matchedUserIds, updatedAt: Timestamp.now() } });
  }
  if (updates.length) await commitUpdates(updates);
}
async function expireBiometricProfile(uid, expiredAt) {
  const userRef = db.doc(`users/${uid}`);
  const eventRefs = await userRef.collection("eventRefs").get();
  for (const eventRefDoc of eventRefs.docs) {
    const eventId = eventRefDoc.id;
    const participantRef = db.doc(`events/${eventId}/participants/${uid}`);
    if ((await participantRef.get()).exists) await participantRef.delete();
    await scrubUserFromEventPhotos(eventId, uid);
  }

  const batch = db.batch();
  batch.delete(db.doc(`users/${uid}/faceProfile/current`));
  batch.set(userRef, { hasFaceProfile: false }, { merge: true });
  batch.set(db.doc(`users/${uid}/privacy/biometricConsent`), {
    expiredAt,
    expirationReason: "12-month-biometric-inactivity",
  }, { merge: true });
  await batch.commit();
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
  if (typeof event.joinCode === "string" && event.joinCode) lookupRefs.push(db.doc(`joinCodes/${event.joinCode}`));
  if (typeof event.inviteToken === "string" && event.inviteToken) lookupRefs.push(db.doc(`inviteTokens/${event.inviteToken}`));
  if (lookupRefs.length) await commitDeletes(lookupRefs);
  try { await admin.storage().bucket().deleteFiles({ prefix: `events/${eventId}/` }); }
  catch (error) { console.error("Trip storage cleanup failed", { eventId, error }); }
  await db.doc(`events/${eventId}`).delete();
}

function callableTemplates(rawTemplates) {
  if (!Array.isArray(rawTemplates)) return [];
  return rawTemplates.filter((item) => item && Array.isArray(item.embedding) && item.embedding.length > 0).map((item) => ({
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
  if (typeof data.userId === "string" && data.userId !== uid) throw new HttpsError("permission-denied", "Consent identity does not match the signed-in user.");

  const requestedVersion = Number(data.policyVersion);
  if (requestedVersion !== CONSENT_POLICY_VERSION
      || data.disclosureId !== CONSENT_DISCLOSURE_ID
      || data.disclosureSHA256 !== CONSENT_DISCLOSURE_SHA256) {
    throw new HttpsError("failed-precondition", "Please review the current Face Match Consent before continuing.");
  }

  const country = normalizeCode(data.jurisdictionCountry, "jurisdictionCountry");
  const subdivision = normalizeCode(data.jurisdictionSubdivision, "jurisdictionSubdivision");
  if (!jurisdictionIsSupported(country, subdivision)) {
    throw new HttpsError("failed-precondition", jurisdictionUnavailableMessage(country, subdivision));
  }

  const acceptedVia = boundedString(data.acceptedVia, "acceptedVia", 64);
  if (acceptedVia !== CONSENT_METHOD) throw new HttpsError("invalid-argument", "Consent method is invalid.");
  const appVersion = boundedString(data.appVersion, "appVersion", 64);
  const platform = boundedString(data.platform, "platform", 32);
  const locale = boundedString(data.locale, "locale", 64);

  const acceptedAt = Timestamp.now();
  await db.doc(`users/${uid}/privacy/biometricConsent`).set({
    userId: uid,
    policyVersion: CONSENT_POLICY_VERSION,
    disclosureId: CONSENT_DISCLOSURE_ID,
    disclosureSHA256: CONSENT_DISCLOSURE_SHA256,
    acceptedAt,
    withdrawnAt: null,
    expiredAt: null,
    lastBiometricActivityAt: null,
    jurisdictionCountry: country,
    jurisdictionSubdivision: subdivision,
    jurisdictionBasis: "user-declared-residence",
    jurisdictionDeclaredAt: acceptedAt,
    appVersion,
    platform,
    locale,
    acceptedVia: CONSENT_METHOD,
  }, { merge: false });

  return {
    accepted: true,
    policyVersion: CONSENT_POLICY_VERSION,
    disclosureId: CONSENT_DISCLOSURE_ID,
    acceptedAtMillis: acceptedAt.toMillis(),
    jurisdictionCountry: country,
    jurisdictionSubdivision: subdivision,
  };
});

exports.saveMyFaceProfile = onCall(async (request) => {
  const uid = requireAuth(request);
  const data = request.data || {};
  if (typeof data.userId === "string" && data.userId !== uid) throw new HttpsError("permission-denied", "Face profile identity does not match the signed-in user.");

  const [consentSnap, userSnap] = await Promise.all([
    db.doc(`users/${uid}/privacy/biometricConsent`).get(),
    db.doc(`users/${uid}`).get(),
  ]);
  if (!userSnap.exists) throw new HttpsError("failed-precondition", "Your SnapLoop user profile is missing.");
  const consent = consentSnap.exists ? consentSnap.data() || {} : null;
  if (!consentIsActive(consent)) throw new HttpsError("failed-precondition", "Active current Face Match consent is required before Face Setup can be stored.");

  const version = Number(data.version);
  if (version !== FACE_PROFILE_VERSION) throw new HttpsError("failed-precondition", "Please update Face Setup using the current face model.");

  const now = Timestamp.now();
  const embedding = requireEmbedding(data.embedding, "embedding");
  const templates = requireTemplates(data.templates, now);
  const expiresAt = Timestamp.fromMillis(now.toMillis() + BIOMETRIC_INACTIVITY_MS);
  const profileRef = db.doc(`users/${uid}/faceProfile/current`);
  const consentRef = db.doc(`users/${uid}/privacy/biometricConsent`);
  const userRef = db.doc(`users/${uid}`);

  const batch = db.batch();
  batch.set(profileRef, {
    userId: uid,
    embedding,
    templates,
    version: FACE_PROFILE_VERSION,
    updatedAt: now,
    lastBiometricActivityAt: now,
    expiresAt,
    consentPolicyVersion: CONSENT_POLICY_VERSION,
    consentDisclosureId: CONSENT_DISCLOSURE_ID,
    consentDisclosureSHA256: CONSENT_DISCLOSURE_SHA256,
  }, { merge: false });
  batch.set(consentRef, { lastBiometricActivityAt: now }, { merge: true });
  batch.set(userRef, { hasFaceProfile: true }, { merge: true });
  await batch.commit();

  return { saved: true, version: FACE_PROFILE_VERSION, expiresAtMillis: expiresAt.toMillis() };
});

exports.listEventFaceProfiles = onCall(async (request) => {
  const uid = requireAuth(request);
  const eventId = requireString((request.data || {}).eventId, "eventId");
  const [eventSnap, callerMember] = await Promise.all([
    db.doc(`events/${eventId}`).get(),
    db.doc(`events/${eventId}/members/${uid}`).get(),
  ]);
  if (!eventSnap.exists) throw new HttpsError("not-found", "This Event does not exist.");
  if (!callerMember.exists) throw new HttpsError("permission-denied", "Join this Event first.");
  const event = eventSnap.data() || {};
  if (event.status !== "active") throw new HttpsError("failed-precondition", "Face matching is available only for an active Event.");

  const members = await db.collection(`events/${eventId}/members`).get();
  const result = [];
  const activityUpdates = [];
  const now = Timestamp.now();
  const nextExpiry = Timestamp.fromMillis(now.toMillis() + BIOMETRIC_INACTIVITY_MS);

  for (const member of members.docs) {
    const profileRef = db.doc(`users/${member.id}/faceProfile/current`);
    const consentRef = db.doc(`users/${member.id}/privacy/biometricConsent`);
    const [profileSnap, userSnap, consentSnap] = await Promise.all([
      profileRef.get(),
      db.doc(`users/${member.id}`).get(),
      consentRef.get(),
    ]);
    if (!profileSnap.exists || !consentSnap.exists) continue;

    const profile = profileSnap.data() || {};
    const consent = consentSnap.data() || {};
    if (!consentIsActive(consent)) continue;
    if (Number(profile.consentPolicyVersion) !== CONSENT_POLICY_VERSION
        || profile.consentDisclosureId !== CONSENT_DISCLOSURE_ID
        || profile.consentDisclosureSHA256 !== CONSENT_DISCLOSURE_SHA256) continue;
    if (profile.expiresAt instanceof Timestamp && profile.expiresAt.toMillis() <= now.toMillis()) continue;
    if (!Array.isArray(profile.embedding) || profile.embedding.length !== FACE_EMBEDDING_DIMENSION) continue;

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

    activityUpdates.push({ ref: profileRef, data: { lastBiometricActivityAt: now, expiresAt: nextExpiry } });
    activityUpdates.push({ ref: consentRef, data: { lastBiometricActivityAt: now } });
  }

  if (activityUpdates.length) await commitUpdates(activityUpdates);
  return { eventId, participants: result };
});

exports.scrubParticipantBiometrics = onDocumentWritten("events/{eventId}/participants/{userId}", async (event) => {
  const after = event.data && event.data.after;
  if (!after || !after.exists) return;
  const data = after.data() || {};
  if (!Object.prototype.hasOwnProperty.call(data, "faceEmbedding") && !Object.prototype.hasOwnProperty.call(data, "faceTemplates")) return;
  await after.ref.update({ faceEmbedding: FieldValue.delete(), faceTemplates: FieldValue.delete() });
});

exports.scrubLegacyParticipantBiometrics = onSchedule("every 24 hours", async () => {
  const snap = await db.collectionGroup("participants").limit(500).get();
  const updates = [];
  for (const doc of snap.docs) {
    const data = doc.data() || {};
    if (Object.prototype.hasOwnProperty.call(data, "faceEmbedding") || Object.prototype.hasOwnProperty.call(data, "faceTemplates")) {
      updates.push({ ref: doc.ref, data: { faceEmbedding: FieldValue.delete(), faceTemplates: FieldValue.delete() } });
    }
  }
  if (updates.length) await commitUpdates(updates);
});

// Deletes account-level biometric templates and expires their consent after
// 12 months with no actual biometric use. Older profiles are backfilled with an
// expiry derived from their last use or update time so legacy data cannot live
// indefinitely merely because it predates this policy.
exports.purgeExpiredBiometricProfiles = onSchedule("every 24 hours", async () => {
  const now = Timestamp.now();
  const expired = await db.collectionGroup("faceProfile").where("expiresAt", "<=", now).limit(250).get();
  const processed = new Set();
  for (const doc of expired.docs) {
    const uid = doc.ref.parent.parent && doc.ref.parent.parent.id;
    if (!uid || processed.has(uid)) continue;
    processed.add(uid);
    await expireBiometricProfile(uid, now);
  }

  const legacy = await db.collectionGroup("faceProfile").limit(500).get();
  for (const doc of legacy.docs) {
    const uid = doc.ref.parent.parent && doc.ref.parent.parent.id;
    if (!uid || processed.has(uid)) continue;
    const data = doc.data() || {};
    if (data.expiresAt instanceof Timestamp) continue;
    const anchor = data.lastBiometricActivityAt instanceof Timestamp
      ? data.lastBiometricActivityAt
      : (data.updatedAt instanceof Timestamp ? data.updatedAt : now);
    const expiryMillis = anchor.toMillis() + BIOMETRIC_INACTIVITY_MS;
    if (expiryMillis <= now.toMillis()) {
      processed.add(uid);
      await expireBiometricProfile(uid, now);
    } else {
      await doc.ref.set({ expiresAt: Timestamp.fromMillis(expiryMillis) }, { merge: true });
    }
  }
});

// A manual delete records the deletion time but keeps the same maximum 15-day
// retention window. The scheduled cleanup below performs the complete purge.
exports.purgeDeletedTripPreviews = onDocumentWritten("events/{eventId}", async (event) => {
  const after = event.data && event.data.after;
  if (!after || !after.exists) return;
  const next = after.data() || {};
  const prior = event.data.before && event.data.before.exists ? event.data.before.data() || {} : {};
  if (next.status !== "deletedByOrganizer" || prior.status === "deletedByOrganizer") return;
  await after.ref.set({ deletedAt: Timestamp.now(), updatedAt: Timestamp.now() }, { merge: true });
});

// Ended Events are fully removed no later than 15 days after their selected end.
exports.purgeExpiredTripPreviews = onSchedule("every 60 minutes", async () => {
  const cutoff = Timestamp.fromMillis(Date.now() - FIFTEEN_DAY_CLEANUP_AFTER_MS);
  const snap = await db.collection("events").where("endsAt", "<=", cutoff).limit(250).get();
  for (const doc of snap.docs) await hardDeleteTrip(doc.id, doc.data() || {});
});

// Manually deleted Events follow the same 15-day maximum, anchored to deletion.
exports.hardDeleteDeletedTrips = onSchedule("every 60 minutes", async () => {
  const snap = await db.collection("events").where("status", "==", "deletedByOrganizer").limit(250).get();
  const now = Date.now();
  for (const doc of snap.docs) {
    const event = doc.data() || {};
    const deletedAt = event.deletedAt instanceof Timestamp ? event.deletedAt.toMillis() : (event.updatedAt instanceof Timestamp ? event.updatedAt.toMillis() : now);
    if (now - deletedAt < FIFTEEN_DAY_CLEANUP_AFTER_MS) continue;
    await hardDeleteTrip(doc.id, event);
  }
});
