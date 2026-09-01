const { randomUUID } = require("crypto");
const { onCall, HttpsError } = require("firebase-functions/https");
const admin = require("firebase-admin");
const { Timestamp } = require("firebase-admin/firestore");

const db = admin.firestore();
const CONSENT_POLICY_VERSION = 5;
const CONSENT_DISCLOSURE_ID = "biometric-consent-v5";
const CONSENT_DISCLOSURE_SHA256 = "2b78a5de4ced7219953cf4c3b62e07dce41392b0090f7c07c3fcb307411bc30f";
const FACE_PROFILE_VERSION = 5;

function requireAuth(request) {
  if (!request.auth || !request.auth.uid) throw new HttpsError("unauthenticated", "You must be signed in.");
  return request.auth.uid;
}

function profileRevision(profile) {
  const version = Number(profile && profile.version || 0);
  const templates = Array.isArray(profile && profile.templates) ? profile.templates : [];
  const ids = templates.map((item) => item && typeof item.id === "string" ? item.id.trim() : "").filter(Boolean).sort();
  return version > 0 && ids.length ? `v${version}:${ids.join("|")}` : null;
}

function currentConsent(consent) {
  return !!consent
    && Number(consent.policyVersion) === CONSENT_POLICY_VERSION
    && consent.disclosureId === CONSENT_DISCLOSURE_ID
    && consent.disclosureSHA256 === CONSENT_DISCLOSURE_SHA256
    && consent.withdrawnAt == null
    && consent.expiredAt == null
    && consent.expiresAt instanceof Timestamp
    && consent.expiresAt.toMillis() > Date.now()
    && consent.age18Attested === true
    && consent.noticeAcknowledged === true
    && consent.ownFaceAttested === true;
}

async function commitUpdates(items) {
  for (let offset = 0; offset < items.length; offset += 350) {
    const batch = db.batch();
    for (const item of items.slice(offset, offset + 350)) batch.update(item.ref, item.data);
    await batch.commit();
  }
}

exports.ensureMyFaceIdentity = onCall(async (request) => {
  const uid = requireAuth(request);
  const profileRef = db.doc(`users/${uid}/faceProfile/current`);
  const consentRef = db.doc(`users/${uid}/privacy/biometricConsent`);
  const [profileSnap, consentSnap] = await Promise.all([profileRef.get(), consentRef.get()]);
  if (!profileSnap.exists) throw new HttpsError("failed-precondition", "Face Setup is missing.");

  const profile = profileSnap.data() || {};
  const consent = consentSnap.exists ? consentSnap.data() || {} : null;
  const revision = profileRevision(profile);
  if (Number(profile.version) !== FACE_PROFILE_VERSION || !revision || !currentConsent(consent)) {
    throw new HttpsError("failed-precondition", "Current Face Setup consent is required before identity migration.");
  }
  if (Number(profile.consentPolicyVersion) !== CONSENT_POLICY_VERSION
      || profile.consentDisclosureId !== CONSENT_DISCLOSURE_ID
      || profile.consentDisclosureSHA256 !== CONSENT_DISCLOSURE_SHA256) {
    throw new HttpsError("failed-precondition", "Face Setup must use the current consent version.");
  }

  let faceIdentityId = typeof profile.faceIdentityId === "string" ? profile.faceIdentityId.trim() : "";
  if (!faceIdentityId) {
    faceIdentityId = randomUUID();
    await profileRef.set({ faceIdentityId, identityRevision: revision }, { merge: true });
  }

  const eventRefs = await db.collection(`users/${uid}/eventRefs`).get();
  let migratedMatches = 0;
  for (const eventRef of eventRefs.docs) {
    const eventId = eventRef.id;
    const photos = await db.collection(`events/${eventId}/photos`).where("matchedUserIds", "array-contains", uid).get();
    const updates = [];

    for (const doc of photos.docs) {
      const data = doc.data() || {};
      const revisions = data.matchedProfileRevisions && typeof data.matchedProfileRevisions === "object"
        ? data.matchedProfileRevisions
        : {};
      if (revisions[uid] !== revision) continue;

      const appearances = Array.isArray(data.appearances) ? data.appearances : [];
      let changed = false;
      const nextAppearances = appearances.map((appearance) => {
        if (!appearance || appearance.participantUserId !== uid || appearance.faceProfileRevision !== revision) return appearance;
        if (appearance.faceIdentityId === faceIdentityId) return appearance;
        changed = true;
        return { ...appearance, faceIdentityId };
      });
      if (!changed) continue;

      const identities = data.matchedFaceIdentityIds && typeof data.matchedFaceIdentityIds === "object"
        ? { ...data.matchedFaceIdentityIds }
        : {};
      identities[uid] = faceIdentityId;
      updates.push({ ref: doc.ref, data: { appearances: nextAppearances, matchedFaceIdentityIds: identities, updatedAt: Timestamp.now() } });
    }

    if (updates.length) {
      await commitUpdates(updates);
      migratedMatches += updates.length;
    }
  }

  return { faceIdentityId, identityRevision: revision, migratedMatches };
});
