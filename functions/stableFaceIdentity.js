const { randomUUID } = require("crypto");
const { onCall, HttpsError } = require("firebase-functions/https");
const admin = require("firebase-admin");
const { Timestamp } = require("firebase-admin/firestore");
const { ensureMembershipIdentities } = require("./membershipIdentity");

const db = admin.firestore();

const DAY_MS = 24 * 60 * 60 * 1000;
const BIOMETRIC_INACTIVITY_MS = 365 * DAY_MS;
const CONSENT_POLICY_VERSION = 5;
const CONSENT_DISCLOSURE_ID = "biometric-consent-v5";
const CONSENT_DISCLOSURE_SHA256 = "2b78a5de4ced7219953cf4c3b62e07dce41392b0090f7c07c3fcb307411bc30f";
const FACE_PROFILE_VERSION = 5;
const FACE_EMBEDDING_DIMENSION = 512;
const MIN_FACE_TEMPLATES = 3;
const MAX_FACE_TEMPLATES = 5;
const MATCH_THRESHOLD = 0.52;
const CORROBORATED_BEST_FLOOR = MATCH_THRESHOLD - 0.04;
const SUPPORTING_FLOOR = MATCH_THRESHOLD - 0.06;
const STRONG_SINGLE_FLOOR = MATCH_THRESHOLD + 0.10;
const BIOMETRIC_POLICY_PATH = "systemConfig/biometricFaceMatch";
const VALID_POSES = new Set(["center", "sideA", "sideB", "tilted", "alternate", "imported"]);
const CANADIAN_SUBDIVISIONS = new Set(["AB", "BC", "MB", "NB", "NL", "NS", "NT", "NU", "ON", "PE", "QC", "SK", "YT"]);
const BLOCKED_CANADIAN_SUBDIVISIONS = new Set(["QC"]);

function requireAuth(request) {
  if (!request.auth || !request.auth.uid) throw new HttpsError("unauthenticated", "You must be signed in.");
  return request.auth.uid;
}

function requireString(value, name) {
  if (typeof value !== "string" || !value.trim()) throw new HttpsError("invalid-argument", `${name} is required.`);
  return value.trim();
}

function jurisdictionIsStaticallySupported(country, subdivision) {
  if (country === "IN") return subdivision === "";
  if (country === "CA") return CANADIAN_SUBDIVISIONS.has(subdivision) && !BLOCKED_CANADIAN_SUBDIVISIONS.has(subdivision);
  return false;
}

function jurisdictionKey(country, subdivision) {
  return subdivision ? `${country}-${subdivision}` : country;
}

async function loadBiometricFeaturePolicy() {
  const snap = await db.doc(BIOMETRIC_POLICY_PATH).get();
  if (!snap.exists) return { enabled: true, blockedJurisdictions: new Set() };
  const data = snap.data() || {};
  const blocked = Array.isArray(data.blockedJurisdictions)
    ? data.blockedJurisdictions
        .filter((value) => typeof value === "string")
        .map((value) => value.trim().toUpperCase())
    : [];
  return { enabled: data.enabled !== false, blockedJurisdictions: new Set(blocked) };
}

function policyAllowsJurisdiction(policy, country, subdivision) {
  return policy.enabled
    && jurisdictionIsStaticallySupported(country, subdivision)
    && !policy.blockedJurisdictions.has(country)
    && !policy.blockedJurisdictions.has(jurisdictionKey(country, subdivision));
}

function consentIsCurrent(consent) {
  if (!consent) return false;
  const country = typeof consent.jurisdictionCountry === "string" ? consent.jurisdictionCountry.toUpperCase() : "";
  const subdivision = typeof consent.jurisdictionSubdivision === "string" ? consent.jurisdictionSubdivision.toUpperCase() : "";
  return Number(consent.policyVersion) === CONSENT_POLICY_VERSION
    && consent.disclosureId === CONSENT_DISCLOSURE_ID
    && consent.disclosureSHA256 === CONSENT_DISCLOSURE_SHA256
    && consent.withdrawnAt == null
    && consent.expiredAt == null
    && consent.expiresAt instanceof Timestamp
    && consent.expiresAt.toMillis() > Date.now()
    && consent.age18Attested === true
    && consent.noticeAcknowledged === true
    && consent.ownFaceAttested === true
    && jurisdictionIsStaticallySupported(country, subdivision);
}

function consentJurisdiction(consent) {
  return {
    country: typeof consent.jurisdictionCountry === "string" ? consent.jurisdictionCountry.toUpperCase() : "",
    subdivision: typeof consent.jurisdictionSubdivision === "string" ? consent.jurisdictionSubdivision.toUpperCase() : "",
  };
}

function requireEmbedding(raw, name) {
  if (!Array.isArray(raw) || raw.length !== FACE_EMBEDDING_DIMENSION) {
    throw new HttpsError("invalid-argument", `${name} must be a ${FACE_EMBEDDING_DIMENSION}-dimension embedding.`);
  }
  const vector = raw.map(Number);
  if (vector.some((value) => !Number.isFinite(value))) throw new HttpsError("invalid-argument", `${name} contains invalid values.`);
  const norm = Math.sqrt(vector.reduce((sum, value) => sum + (value * value), 0));
  if (!Number.isFinite(norm) || norm < 0.90 || norm > 1.10) throw new HttpsError("invalid-argument", `${name} is not normalized.`);
  return vector;
}

function requireTemplates(rawTemplates, now) {
  if (!Array.isArray(rawTemplates) || rawTemplates.length < MIN_FACE_TEMPLATES || rawTemplates.length > MAX_FACE_TEMPLATES) {
    throw new HttpsError("invalid-argument", `Face Setup must contain ${MIN_FACE_TEMPLATES}-${MAX_FACE_TEMPLATES} enrollment templates.`);
  }
  return rawTemplates.map((item, index) => {
    if (!item || typeof item !== "object") throw new HttpsError("invalid-argument", "Face template is invalid.");
    const id = requireString(item.id, `templates[${index}].id`);
    if (id.length > 128) throw new HttpsError("invalid-argument", "Face template id is too long.");
    const embedding = requireEmbedding(item.embedding, `templates[${index}].embedding`);
    const pose = requireString(item.pose, `templates[${index}].pose`);
    if (!VALID_POSES.has(pose)) throw new HttpsError("invalid-argument", "Face template pose is invalid.");
    const quality = Number(item.quality);
    if (!Number.isFinite(quality) || quality < 0 || quality > 1) throw new HttpsError("invalid-argument", "Face template quality is invalid.");
    const requestedCreatedAt = Number(item.createdAtMillis);
    const createdAtMillis = Number.isFinite(requestedCreatedAt) ? Math.min(now.toMillis(), Math.max(0, requestedCreatedAt)) : now.toMillis();
    return { id, embedding, pose, quality, createdAt: Timestamp.fromMillis(createdAtMillis) };
  });
}

function profileRevision(version, templates) {
  const ids = Array.isArray(templates)
    ? templates.map((item) => item && typeof item.id === "string" ? item.id.trim() : "").filter(Boolean).sort()
    : [];
  return ids.length ? `v${version}:${ids.join("|")}` : null;
}

function cosineSimilarity(lhs, rhs) {
  if (!Array.isArray(lhs) || !Array.isArray(rhs) || lhs.length !== rhs.length || !lhs.length) return null;
  let dot = 0;
  let leftNorm = 0;
  let rightNorm = 0;
  for (let i = 0; i < lhs.length; i += 1) {
    dot += lhs[i] * rhs[i];
    leftNorm += lhs[i] * lhs[i];
    rightNorm += rhs[i] * rhs[i];
  }
  if (leftNorm <= 0 || rightNorm <= 0) return null;
  return dot / (Math.sqrt(leftNorm) * Math.sqrt(rightNorm));
}

function templateMatchAccepted(queryEmbedding, referenceTemplates) {
  const scores = referenceTemplates
    .map((template) => cosineSimilarity(queryEmbedding, template.embedding))
    .filter((value) => Number.isFinite(value))
    .sort((a, b) => b - a);
  if (!scores.length) return false;
  const best = scores[0];
  const second = scores.length > 1 ? scores[1] : null;
  return (best >= CORROBORATED_BEST_FLOOR && second !== null && second >= SUPPORTING_FLOOR)
    || best >= STRONG_SINGLE_FLOOR;
}

function sameIdentityReplacement(existingProfile, newTemplates) {
  if (!existingProfile || Number(existingProfile.version) !== FACE_PROFILE_VERSION) return false;
  const oldTemplates = Array.isArray(existingProfile.templates)
    ? existingProfile.templates.filter((item) => item && Array.isArray(item.embedding) && item.embedding.length === FACE_EMBEDDING_DIMENSION)
    : [];
  if (oldTemplates.length < 2) return false;
  const accepted = newTemplates.reduce((count, template) => count + (templateMatchAccepted(template.embedding, oldTemplates) ? 1 : 0), 0);
  const required = Math.max(2, Math.ceil(newTemplates.length * 0.60));
  return accepted >= required;
}

function callableTemplates(rawTemplates) {
  if (!Array.isArray(rawTemplates)) return [];
  return rawTemplates.filter((item) => item && Array.isArray(item.embedding)).map((item) => ({
    id: typeof item.id === "string" ? item.id : null,
    embedding: item.embedding,
    pose: typeof item.pose === "string" ? item.pose : "alternate",
    quality: Number(item.quality || 1),
    createdAtMillis: item.createdAt instanceof Timestamp ? item.createdAt.toMillis() : Date.now(),
  }));
}

exports.saveMyFaceProfile = onCall(async (request) => {
  const uid = requireAuth(request);
  const data = request.data || {};
  if (typeof data.userId === "string" && data.userId !== uid) throw new HttpsError("permission-denied", "Face profile identity does not match the signed-in user.");

  const profileRef = db.doc(`users/${uid}/faceProfile/current`);
  const consentRef = db.doc(`users/${uid}/privacy/biometricConsent`);
  const [consentSnap, userSnap, policy, existingProfileSnap] = await Promise.all([
    consentRef.get(),
    db.doc(`users/${uid}`).get(),
    loadBiometricFeaturePolicy(),
    profileRef.get(),
  ]);
  if (!userSnap.exists) throw new HttpsError("failed-precondition", "Your SnapLoop user profile is missing.");
  const consent = consentSnap.exists ? consentSnap.data() || {} : null;
  if (!consentIsCurrent(consent)) throw new HttpsError("failed-precondition", "Active current Face Match consent is required before Face Setup can be stored.");
  const jurisdiction = consentJurisdiction(consent);
  if (!policyAllowsJurisdiction(policy, jurisdiction.country, jurisdiction.subdivision)) {
    throw new HttpsError("failed-precondition", "Face Match is not currently available in your declared jurisdiction.");
  }

  const version = Number(data.version);
  if (version !== FACE_PROFILE_VERSION) throw new HttpsError("failed-precondition", "Please update Face Setup using the current face model.");

  const now = Timestamp.now();
  const embedding = requireEmbedding(data.embedding, "embedding");
  const templates = requireTemplates(data.templates, now);
  const identityRevision = profileRevision(version, templates);
  if (!identityRevision) throw new HttpsError("invalid-argument", "Face Setup revision could not be created.");

  let faceIdentityId;
  if (existingProfileSnap.exists) {
    const existing = existingProfileSnap.data() || {};
    if (!sameIdentityReplacement(existing, templates)) {
      throw new HttpsError(
        "failed-precondition",
        "This scan does not match your current Face Setup. To use a different face, delete the current Face Setup and start again."
      );
    }
    faceIdentityId = typeof existing.faceIdentityId === "string" && existing.faceIdentityId.trim()
      ? existing.faceIdentityId.trim()
      : randomUUID();
  } else {
    faceIdentityId = randomUUID();
  }

  const expiresAt = Timestamp.fromMillis(now.toMillis() + BIOMETRIC_INACTIVITY_MS);
  const batch = db.batch();
  batch.set(profileRef, {
    userId: uid,
    faceIdentityId,
    identityRevision,
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
  batch.set(consentRef, { lastBiometricActivityAt: now, expiresAt }, { merge: true });
  batch.set(db.doc(`users/${uid}`), { hasFaceProfile: true }, { merge: true });
  await batch.commit();

  return { saved: true, version: FACE_PROFILE_VERSION, faceIdentityId, identityRevision, expiresAtMillis: expiresAt.toMillis() };
});

exports.listEventFaceProfiles = onCall(async (request) => {
  const uid = requireAuth(request);
  const eventId = requireString((request.data || {}).eventId, "eventId");
  const [eventSnap, callerMember, policy] = await Promise.all([
    db.doc(`events/${eventId}`).get(),
    db.doc(`events/${eventId}/members/${uid}`).get(),
    loadBiometricFeaturePolicy(),
  ]);
  if (!policy.enabled) throw new HttpsError("failed-precondition", "Face Match is temporarily unavailable.");
  if (!eventSnap.exists) throw new HttpsError("not-found", "This Event does not exist.");
  if (!callerMember.exists) throw new HttpsError("permission-denied", "Join this Event first.");
  if ((eventSnap.data() || {}).status !== "active") throw new HttpsError("failed-precondition", "Face matching is available only for an active Event.");

  const members = await db.collection(`events/${eventId}/members`).get();
  // Bind every returned biometric descriptor to the authoritative participation
  // generation from the same member snapshot. If a member leaves while a legacy
  // ID is being backfilled, ensureMembershipIdentities refuses to recreate that
  // deleted membership and we simply omit the stale roster row.
  const membershipIds = await ensureMembershipIdentities(
    eventId,
    members.docs.map((member) => ({ userId: member.id, data: member.data() || {} }))
  );
  const callerMembershipId = membershipIds.get(uid);
  if (!callerMembershipId) {
    // The caller left while the roster was being assembled. Do not return a
    // manifest that could later publish work under an unknown membership epoch.
    throw new HttpsError("permission-denied", "Join this Event first.");
  }

  const result = [];
  const now = Timestamp.now();
  const nextExpiry = Timestamp.fromMillis(now.toMillis() + BIOMETRIC_INACTIVITY_MS);

  for (const member of members.docs) {
    const membershipId = membershipIds.get(member.id);
    if (!membershipId) continue;

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
    if (!consentIsCurrent(consent)) continue;
    const jurisdiction = consentJurisdiction(consent);
    if (!policyAllowsJurisdiction(policy, jurisdiction.country, jurisdiction.subdivision)) continue;
    if (Number(profile.consentPolicyVersion) !== CONSENT_POLICY_VERSION
        || profile.consentDisclosureId !== CONSENT_DISCLOSURE_ID
        || profile.consentDisclosureSHA256 !== CONSENT_DISCLOSURE_SHA256) continue;
    if (!(profile.expiresAt instanceof Timestamp) || profile.expiresAt.toMillis() <= now.toMillis()) continue;
    if (!Array.isArray(profile.embedding) || profile.embedding.length !== FACE_EMBEDDING_DIMENSION) continue;
    if (typeof profile.faceIdentityId !== "string" || !profile.faceIdentityId.trim()) continue;
    if (!profileRevision(Number(profile.version || 0), profile.templates)) continue;

    const user = userSnap.exists ? userSnap.data() || {} : {};
    const memberData = member.data() || {};
    result.push({
      userId: member.id,
      membershipId,
      displayName: user.displayName || null,
      faceIdentityId: profile.faceIdentityId.trim(),
      faceEmbedding: profile.embedding,
      faceTemplates: callableTemplates(profile.templates),
      faceProfileVersion: Number(profile.version || 1),
      faceProfileRevision: profileRevision(Number(profile.version || 0), profile.templates),
      joinedAtMillis: memberData.joinedAt instanceof Timestamp ? memberData.joinedAt.toMillis() : Date.now(),
    });

    if (member.id === uid) {
      await profileRef.set({ lastBiometricActivityAt: now, expiresAt: nextExpiry }, { merge: true });
      await consentRef.set({ lastBiometricActivityAt: now, expiresAt: nextExpiry }, { merge: true });
    }
  }

  return { eventId, callerMembershipId, participants: result };
});
