const { onCall, HttpsError } = require("firebase-functions/https");
const admin = require("firebase-admin");
const { Timestamp } = require("firebase-admin/firestore");
const { normalizedMembershipId } = require("./membershipIdentity");
const { deduplicateMatchedPhotos } = require("./matchReadDedup");

const db = admin.firestore();

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

function appearanceAllowsViewer(data, uid, currentIdentity, currentMembershipId) {
  const identityMap = data.matchedFaceIdentityIds && typeof data.matchedFaceIdentityIds === "object"
    ? data.matchedFaceIdentityIds
    : {};
  if (identityMap[uid] !== currentIdentity) return false;

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

exports.listMyMatchedPhotosIdentityBoundDedup = onCall(async (request) => {
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

  const candidates = [];
  for (const doc of snap.docs) {
    const data = doc.data() || {};
    if (!appearanceAllowsViewer(data, uid, currentIdentity, currentMembershipId)) continue;

    candidates.push({
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
      updatedAtMillis: data.updatedAt instanceof Timestamp ? data.updatedAt.toMillis() : null,
      thumbnailPath: typeof data.thumbnailPath === "string" ? data.thumbnailPath : null,
    });
  }

  const photos = deduplicateMatchedPhotos(candidates)
    .map(({ updatedAtMillis, ...photo }) => photo)
    .sort((a, b) => Number(b.capturedAtMillis || 0) - Number(a.capturedAtMillis || 0));

  return { eventId, photos };
});
