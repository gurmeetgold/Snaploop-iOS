const { onSchedule } = require("firebase-functions/v2/scheduler");
const admin = require("firebase-admin");
const { removeRecipientMatchMetadata } = require("./change4MatchMetadata");

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

async function commitUpdates(items) {
  for (let offset = 0; offset < items.length; offset += 400) {
    const batch = db.batch();
    for (const item of items.slice(offset, offset + 400)) batch.update(item.ref, item.data);
    await batch.commit();
  }
}

async function scrubActiveRecipientMatches(eventId, uid) {
  const snap = await db.collection(`events/${eventId}/photos`)
    .where("matchedUserIds", "array-contains", uid)
    .get();
  const updates = snap.docs.map((doc) => ({
    ref: doc.ref,
    data: {
      ...removeRecipientMatchMetadata(doc.data() || {}, uid),
      updatedAt: Timestamp.now(),
    },
  }));
  if (updates.length) await commitUpdates(updates);
  return updates.length;
}

async function removeActiveBiometricProfile(uid) {
  const userRef = db.doc(`users/${uid}`);
  const eventRefs = await userRef.collection("eventRefs").get();
  let scrubbedPhotos = 0;

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
    scrubbedPhotos += await scrubActiveRecipientMatches(eventId, uid);
  }

  const batch = db.batch();
  batch.delete(db.doc(`users/${uid}/faceProfile/current`));
  batch.set(userRef, { hasFaceProfile: false, updatedAt: Timestamp.now() }, { merge: true });
  await batch.commit();
  return scrubbedPhotos;
}

async function expireBiometricProfile(uid, expiredAt) {
  const scrubbedPhotos = await removeActiveBiometricProfile(uid);
  await db.doc(`users/${uid}/privacy/biometricConsent`).set({
    expiredAt,
    // Clear the queryable deadline after processing so an expired consent cannot
    // permanently occupy the first scheduler page and starve later users.
    expiresAt: null,
    expirationReason: "12-month-biometric-inactivity",
  }, { merge: true });
  return scrubbedPhotos;
}

async function drainExpiredConsents(now, processed) {
  while (true) {
    const snap = await db.collectionGroup("privacy")
      .where("expiresAt", "<=", now)
      .limit(PAGE_SIZE)
      .get();
    if (snap.empty) return;

    let advanced = false;
    for (const doc of snap.docs) {
      if (doc.id !== "biometricConsent") continue;
      const uid = doc.ref.parent.parent && doc.ref.parent.parent.id;
      if (!uid) continue;
      if (!processed.has(uid)) {
        processed.add(uid);
        await expireBiometricProfile(uid, now);
      } else {
        // A duplicate path for a user should still be removed from this query.
        await doc.ref.set({ expiresAt: null }, { merge: true });
      }
      advanced = true;
    }
    if (!advanced) return;
  }
}

async function drainExpiredProfiles(now, processed) {
  while (true) {
    const snap = await db.collectionGroup("faceProfile")
      .where("expiresAt", "<=", now)
      .limit(PAGE_SIZE)
      .get();
    if (snap.empty) return;

    let advanced = false;
    for (const doc of snap.docs) {
      const uid = doc.ref.parent.parent && doc.ref.parent.parent.id;
      if (!uid) continue;
      if (!processed.has(uid)) {
        processed.add(uid);
        await expireBiometricProfile(uid, now);
      } else if (doc.exists) {
        await doc.ref.delete();
      }
      advanced = true;
    }
    if (!advanced) return;
  }
}

async function scanRemainingProfiles(now, processed) {
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
      const data = doc.data() || {};
      const consentSnap = await db.doc(`users/${uid}/privacy/biometricConsent`).get();
      const consent = consentSnap.exists ? consentSnap.data() || {} : null;
      const currentProfile = Number(data.consentPolicyVersion) === CONSENT_POLICY_VERSION
        && data.consentDisclosureId === CONSENT_DISCLOSURE_ID
        && data.consentDisclosureSHA256 === CONSENT_DISCLOSURE_SHA256;

      if (!currentProfile) {
        processed.add(uid);
        await removeActiveBiometricProfile(uid);
        continue;
      }

      if (!consentIsCurrent(consent, now.toMillis())) {
        processed.add(uid);
        if (consent && consent.expiresAt instanceof Timestamp
            && consent.expiresAt.toMillis() <= now.toMillis()) {
          await expireBiometricProfile(uid, now);
        } else {
          await removeActiveBiometricProfile(uid);
        }
        continue;
      }

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

    if (snap.size < PAGE_SIZE) return;
  }

  console.warn("Biometric expiry scan reached safety cap", { scanned });
}

exports.purgeExpiredBiometricProfiles = onSchedule("every 24 hours", async () => {
  const now = Timestamp.now();
  const processed = new Set();
  await drainExpiredConsents(now, processed);
  await drainExpiredProfiles(now, processed);
  await scanRemainingProfiles(now, processed);
});

exports._test = {
  consentIsCurrent,
  jurisdictionIsStaticallySupported,
};
