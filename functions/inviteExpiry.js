const { onSchedule } = require("firebase-functions/v2/scheduler");
const admin = require("firebase-admin");
const { isWithinEventGraceWindow } = require("./eventDateSemantics");

const db = admin.firestore();
const Timestamp = admin.firestore.Timestamp;
const DAY_MS = 24 * 60 * 60 * 1000;
const PHOTO_WINDOW_DAYS = 15;

function phoneKey(phone) {
  return String(phone || "").replace(/\D/g, "");
}

// Event invitations stay usable through the same 15-civil-day post-Event photo
// recovery window as code/link joining. Query one day wider than the canonical
// threshold, then make the authoritative decision from the Event document. This
// keeps DST from expiring an invite an hour early/late while retaining bounded
// collection-group work for legacy records.
exports.expirePendingInvites = onSchedule("every 60 minutes", async () => {
  const nowMillis = Date.now();
  const now = Timestamp.fromMillis(nowMillis);
  const coarseCutoff = Timestamp.fromMillis(nowMillis - 14 * DAY_MS);
  const snap = await db.collectionGroup("pendingInvites")
    .where("status", "==", "invited")
    .where("endsAt", "<", coarseCutoff)
    .limit(200)
    .get();

  for (const doc of snap.docs) {
    const data = doc.data() || {};
    const eventId = data.eventId || doc.id;
    const eventSnap = await db.doc(`events/${eventId}`).get();

    // Missing Events can never become joinable again. Existing Events use the
    // shared v1 civil-day helper; legacy records preserve the old elapsed-time
    // behavior because they do not carry a trustworthy Event timezone.
    const shouldExpire = !eventSnap.exists
      || !isWithinEventGraceWindow(eventSnap.data() || {}, nowMillis, PHOTO_WINDOW_DAYS);
    if (!shouldExpire) continue;

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
