const { onCall, HttpsError } = require("firebase-functions/https");
const admin = require("firebase-admin");
const { Timestamp } = require("firebase-admin/firestore");

const db = admin.firestore();

const DAY_MS = 24 * 60 * 60 * 1000;
const BIOMETRIC_INACTIVITY_MS = 365 * DAY_MS;
const CONSENT_POLICY_VERSION = 5;
const CONSENT_DISCLOSURE_ID = "biometric-consent-v5";
const CONSENT_DISCLOSURE_SHA256 = "2b78a5de4ced7219953cf4c3b62e07dce41392b0090f7c07c3fcb307411bc30f";
const CONSENT_METHOD = "explicit-button";
const BIOMETRIC_POLICY_PATH = "systemConfig/biometricFaceMatch";

function requireAuth(request) {
  if (!request.auth || !request.auth.uid) throw new HttpsError("unauthenticated", "You must be signed in.");
  return request.auth.uid;
}

function boundedString(value, name, maxLength) {
  if (typeof value !== "string" || !value.trim()) throw new HttpsError("invalid-argument", `${name} is required.`);
  const text = value.trim();
  if (text.length > maxLength) throw new HttpsError("invalid-argument", `${name} is too long.`);
  return text;
}

function normalizeCountry(value) {
  return boundedString(value, "jurisdictionCountry", 8).toUpperCase();
}

function normalizeSubdivision(country, value) {
  if (country === "IN") return "";
  return boundedString(value, "jurisdictionSubdivision", 8).toUpperCase();
}

function staticJurisdictionAllowed(country, subdivision) {
  return country === "IN" && subdivision === "";
}

function jurisdictionKey(country, subdivision) {
  return subdivision ? `${country}-${subdivision}` : country;
}

async function policyAllows(country, subdivision) {
  if (!staticJurisdictionAllowed(country, subdivision)) return false;
  const snap = await db.doc(BIOMETRIC_POLICY_PATH).get();
  if (!snap.exists) return true;
  const data = snap.data() || {};
  if (data.enabled === false) return false;
  const blocked = new Set((Array.isArray(data.blockedJurisdictions) ? data.blockedJurisdictions : [])
    .filter((value) => typeof value === "string")
    .map((value) => value.trim().toUpperCase()));
  return !blocked.has(country) && !blocked.has(jurisdictionKey(country, subdivision));
}

exports.acceptBiometricConsent = onCall(async (request) => {
  const uid = requireAuth(request);
  const data = request.data || {};
  if (typeof data.userId === "string" && data.userId !== uid) {
    throw new HttpsError("permission-denied", "Consent identity does not match the signed-in user.");
  }

  if (Number(data.policyVersion) !== CONSENT_POLICY_VERSION
      || data.disclosureId !== CONSENT_DISCLOSURE_ID
      || data.disclosureSHA256 !== CONSENT_DISCLOSURE_SHA256) {
    throw new HttpsError("failed-precondition", "Please review the current Face Match Consent before continuing.");
  }
  if (data.age18Attested !== true || data.noticeAcknowledged !== true || data.ownFaceAttested !== true) {
    throw new HttpsError("failed-precondition", "Age, own-face, and Face Match consent confirmations are required.");
  }

  const country = normalizeCountry(data.jurisdictionCountry);
  const subdivision = normalizeSubdivision(country, data.jurisdictionSubdivision);
  if (!(await policyAllows(country, subdivision))) {
    throw new HttpsError("failed-precondition", "Face Match is not currently available in the selected jurisdiction.");
  }

  const acceptedVia = boundedString(data.acceptedVia, "acceptedVia", 64);
  if (acceptedVia !== CONSENT_METHOD) throw new HttpsError("invalid-argument", "Consent method is invalid.");
  const appVersion = boundedString(data.appVersion, "appVersion", 64);
  const platform = boundedString(data.platform, "platform", 32);
  const locale = boundedString(data.locale, "locale", 64);

  const acceptedAt = Timestamp.now();
  const expiresAt = Timestamp.fromMillis(acceptedAt.toMillis() + BIOMETRIC_INACTIVITY_MS);
  await db.doc(`users/${uid}/privacy/biometricConsent`).set({
    userId: uid,
    policyVersion: CONSENT_POLICY_VERSION,
    disclosureId: CONSENT_DISCLOSURE_ID,
    disclosureSHA256: CONSENT_DISCLOSURE_SHA256,
    acceptedAt,
    withdrawnAt: null,
    expiredAt: null,
    expiresAt,
    expirationReason: null,
    lastBiometricActivityAt: null,
    jurisdictionCountry: country,
    jurisdictionSubdivision: subdivision,
    jurisdictionBasis: "user-declared-residence",
    jurisdictionDeclaredAt: acceptedAt,
    appVersion,
    platform,
    locale,
    acceptedVia: CONSENT_METHOD,
    age18Attested: true,
    noticeAcknowledged: true,
    ownFaceAttested: true,
  }, { merge: false });

  return {
    accepted: true,
    policyVersion: CONSENT_POLICY_VERSION,
    disclosureId: CONSENT_DISCLOSURE_ID,
    acceptedAtMillis: acceptedAt.toMillis(),
    expiresAtMillis: expiresAt.toMillis(),
    jurisdictionCountry: country,
    jurisdictionSubdivision: subdivision,
  };
});
