const { onSchedule } = require("firebase-functions/v2/scheduler");
const admin = require("firebase-admin");

const db = admin.firestore();
const Timestamp = admin.firestore.Timestamp;
const FieldPath = admin.firestore.FieldPath;

const DAY_MS = 24 * 60 * 60 * 1000;
const BIOMETRIC_INACTIVITY_MS = 365 * DAY_MS;
const CONSENT_POLICY_VERSION = 5;
const CONSENT_DISCLOSURE_ID = "biometric-consent-v5";
const CONSENT_DISCLOSURE_SHA256 = "2b78a5de4ced7219953cf4c3b62e07dce41392b0090f7c07c3fcb307411bc30f";
const CANADIAN_SUBDIVISIONS = new Set(["AB", "BC", "MB", "NB", "NL", "NS", "NT", "NU", "ON", "PE", "QC", "SK", "YT"]);
const BLOCKED_CANADIAN_SUBDIVISIONS = new Set(["QC"]);
const PAGE_SIZE = 250;
const MAX_PROFILE_SCAN_PER_RUN = 10_000;
const MAX_EXPIRED_CONSENT_SCAN_PER_RUN = 10_000;

function jurisdictionIsStaticallySupported(country, subdivision) {
  if (country === "IN") return subdivision === "";
  if (country === "CA") return CANADIAN_SUBDIVISIONS.has(subdivision) && !BLOCKED_CANADIAN_SUBDIVISIONS.has(subdivision);
  return false;
}

function consentIsCurrent(consent, nowMillis = Date.now()) {
  if (!consent) return false;
  const country = typeof consent.jurisdictionCountry === "string" ? consent.jurisdictionCountry.toUpperCase() : "";
  const subdivision = typeof consent.jurisdictionSubdivision === "string" ? consent.jurisdictionSubdivision.toUpperCase() : "";
  return Number(consent.policyVersion) === CONSENT_POLICY_VERSION
    && consent.disclosureId === CONSENT_DISCLOSURE_ID
    && consent.disclosureSHA256 === CONSENT_DISCLOSURE_SHA256
    && consent.withdrawnAt == null
    && consent.expiredAt == null
    && consent.expiresAt instanceof Timestamp
    && consent.expiresAt.toMillis() > nowMillis
    && consent.age18Attested === true
    && consent.noticeAcknowledged === true
    && consent.ownFaceAttested === true
    && jurisdictionIsStaticallySupported(country, subdivision);
}

function profileUsesCurrentConsent(profile) {
  return !!profile
    && Number(profile.consentPolicyVersion) === CONSENT_POLICY_VERSION
    && profile.consentDisclosureId === CONSENT_DISCLOSURE_ID
    && profile.consentDisclosureSHA256 === CONSENT_DISCLOSURE_SHA256;
}

async function cleanupLegacyRosterState(uid) {
  // Profile deletion itself is the immediate privacy barrier: list/read paths and
  // Storage Rules require the current profile. The identity-change trigger then
  // scrubs face-derived photo metadata generation-safely. Here we remove only
  // legacy participant snapshots and the local-own-match preference.
  const eventRefs = await db.collection(`users/${uid}/eventRefs`).get();
  for (const eventRefDoc of eventRefs.docs) {
    const eventId = eventRefDoc.id;
    const participantRef = db.doc(`events/${eventId}/participants/${uid}`);
    const memberRef = db.doc(`events/${eventId}/members/${uid}`);
    const [participantSnap, memberSnap] = await Promise.all([
      participantRef.get(),
      memberRef.get(),
    ]);
    if (participantSnap.exists) await participantRef.delete();
    if (memberSnap.exists && memberSnap.data()?.includeOwnMatches === true) {
      await memberRef.update({ includeOwnMatches: false, ownMatchesUpdatedAt: Timestamp.now() });
    }
  }
}

/**
 * Re-evaluates the *current* profile and consent in one transaction. Scheduler
 * query snapshots are only hints: a user may refresh Face Setup/consent on
 * another device while the scheduled job is running. We therefore never delete
 * based on stale query data and never recreate a user/consent document during an
 * account-deletion race.
 */
async function reconcileBiometricExpiry(uid, now) {
  const nowMillis = now.toMillis();
  const userRef = db.doc(`users/${uid}`);
  const profileRef = db.doc(`users/${uid}/faceProfile/current`);
  const consentRef = db.doc(`users/${uid}/privacy/biometricConsent`);

  const outcome = await db.runTransaction(async (tx) => {
    const [userSnap, profileSnap, consentSnap] = await Promise.all([
      tx.get(userRef),
      tx.get(profileRef),
      tx.get(consentRef),
    ]);

    // Account deletion wins. Remove any orphan biometric children but never use
    // merge:true to resurrect a parent/user document that no longer exists.
    if (!userSnap.exists) {
      if (profileSnap.exists) tx.delete(profileRef);
      if (consentSnap.exists) tx.delete(consentRef);
      return { removedProfile: profileSnap.exists, cleanupUser: false };
    }

    const profile = profileSnap.exists ? profileSnap.data() || {} : null;
    const consent = consentSnap.exists ? consentSnap.data() || {} : null;

    if (!profile) {
      // Consent can outlive a deleted Face Setup. If its inactivity deadline has
      // passed, mark it processed and remove the queryable deadline; otherwise
      // there is no biometric material to purge.
      if (consent && consent.expiresAt instanceof Timestamp
          && consent.expiresAt.toMillis() <= nowMillis) {
        tx.set(consentRef, {
          expiredAt: now,
          expiresAt: null,
          expirationReason: "12-month-biometric-inactivity",
        }, { merge: true });
      }
      return { removedProfile: false, cleanupUser: false };
    }

    let removalReason = null;
    let markConsentExpired = false;

    if (!profileUsesCurrentConsent(profile)) {
      removalReason = "profile-policy-mismatch";
    } else if (!consentIsCurrent(consent, nowMillis)) {
      removalReason = "consent-not-current";
      markConsentExpired = !!consent
        && consent.expiresAt instanceof Timestamp
        && consent.expiresAt.toMillis() <= nowMillis;
    } else if (profile.expiresAt instanceof Timestamp) {
      if (profile.expiresAt.toMillis() <= nowMillis) {
        removalReason = "12-month-biometric-inactivity";
        markConsentExpired = true;
      }
    } else {
      const anchor = profile.lastBiometricActivityAt instanceof Timestamp
        ? profile.lastBiometricActivityAt
        : (profile.updatedAt instanceof Timestamp ? profile.updatedAt : now);
      const expiryMillis = anchor.toMillis() + BIOMETRIC_INACTIVITY_MS;
      if (expiryMillis <= nowMillis) {
        removalReason = "12-month-biometric-inactivity";
        markConsentExpired = true;
      } else {
        tx.set(profileRef, { expiresAt: Timestamp.fromMillis(expiryMillis) }, { merge: true });
        return { removedProfile: false, cleanupUser: false };
      }
    }

    if (!removalReason) return { removedProfile: false, cleanupUser: false };

    // Conditional deletion occurs in the same transaction that read the current
    // documents, so a simultaneous Face Setup refresh causes this transaction to
    // retry against the new, non-expired state instead of deleting it.
    tx.delete(profileRef);
    tx.set(userRef, { hasFaceProfile: false, updatedAt: now }, { merge: true });
    if (markConsentExpired && consentSnap.exists) {
      tx.set(consentRef, {
        expiredAt: now,
        expiresAt: null,
        expirationReason: "12-month-biometric-inactivity",
      }, { merge: true });
    }
    return { removedProfile: true, cleanupUser: true, removalReason };
  });

  if (outcome.cleanupUser) await cleanupLegacyRosterState(uid);
  return outcome;
}

async function scanExpiredConsents(now, processed) {
  let lastDoc = null;
  let scanned = 0;

  while (scanned < MAX_EXPIRED_CONSENT_SCAN_PER_RUN) {
    let query = db.collectionGroup("privacy")
      .where("expiresAt", "<=", now)
      .orderBy("expiresAt")
      .limit(Math.min(PAGE_SIZE, MAX_EXPIRED_CONSENT_SCAN_PER_RUN - scanned));
    if (lastDoc) query = query.startAfter(lastDoc);
    const snap = await query.get();
    if (snap.empty) return;

    for (const doc of snap.docs) {
      scanned += 1;
      lastDoc = doc;
      if (doc.id !== "biometricConsent") continue;
      const uid = doc.ref.parent.parent && doc.ref.parent.parent.id;
      if (!uid || processed.has(uid)) continue;
      processed.add(uid);
      await reconcileBiometricExpiry(uid, now);
    }

    if (snap.size < PAGE_SIZE) return;
  }
  console.warn("Expired biometric consent scan reached safety cap", { scanned });
}

async function scanProfiles(now, processed) {
  let lastDoc = null;
  let scanned = 0;

  while (scanned < MAX_PROFILE_SCAN_PER_RUN) {
    let query = db.collectionGroup("faceProfile")
      .orderBy(FieldPath.documentId())
      .limit(Math.min(PAGE_SIZE, MAX_PROFILE_SCAN_PER_RUN - scanned));
    if (lastDoc) query = query.startAfter(lastDoc);
    const snap = await query.get();
    if (snap.empty) return;

    for (const doc of snap.docs) {
      scanned += 1;
      lastDoc = doc;
      const uid = doc.ref.parent.parent && doc.ref.parent.parent.id;
      if (!uid || processed.has(uid)) continue;
      processed.add(uid);
      await reconcileBiometricExpiry(uid, now);
    }

    if (snap.size < PAGE_SIZE) return;
  }
  console.warn("Biometric profile scan reached safety cap", { scanned });
}

exports.purgeExpiredBiometricProfiles = onSchedule("every 24 hours", async () => {
  const now = Timestamp.now();
  const processed = new Set();
  await scanExpiredConsents(now, processed);
  await scanProfiles(now, processed);
});

exports._test = {
  consentIsCurrent,
  jurisdictionIsStaticallySupported,
  profileUsesCurrentConsent,
};
