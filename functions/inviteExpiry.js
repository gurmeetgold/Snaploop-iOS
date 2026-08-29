const { onSchedule } = require("firebase-functions/v2/scheduler");
const admin = require("firebase-admin");

const db = admin.firestore();
const Timestamp = admin.firestore.Timestamp;
const DAY_MS = 24 * 60 * 60 * 1000;
const PHOTO_WINDOW_DAYS = 15;

function phoneKey(phone) {
  return String(phone || "").replace(/\D/g, "");
}

// Event invitations stay usable through the same 15-day post-Event photo
// recovery window as code/link joining. This lets someone who forgot to join
// during the gathering still join later and receive photos of themselves.
exports.expirePendingInvites = onSchedule("every 60 minutes", async () => {
  const now = Timestamp.now();
  const cutoff = Timestamp.fromMillis(Date.now() - PHOTO_WINDOW_DAYS * DAY_MS);
  const snap = await db.collectionGroup("pendingInvites")
    .where("status", "==", "invited")
    .where("endsAt", "<", cutoff)
    .limit(200)
    .get();

  for (const doc of snap.docs) {
    const data = doc.data() || {};
    const eventId = data.eventId || doc.id;
    const batch = db.batch();
    batch.set(doc.ref, { status: "expired", updatedAt: now }, { merge: true });
    if (data.phoneNumber) {
      batch.set(
        db.doc(`events/${eventId}/invites/${phoneKey(data.phoneNumber)}`),
        { status: "expired", updatedAt: now },
        { merge: true }
      );
    }
    await batch.commit();
  }
});
