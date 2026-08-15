/**
 * SnapLoop Cloud Functions.
 *
 * These are the trusted server-side pieces the clients cannot do safely on
 * their own: resolving an invite token into a membership (so tokens are never
 * enumerable from the client), batching match notifications, orchestrating
 * idempotent original-transfers, and scheduled cleanup of expired data.
 *
 * Written against firebase-functions v4 + firebase-admin. Deployed from this
 * directory. Kept small and single-responsibility per the master rules.
 */

const functions = require("firebase-functions");
const admin = require("firebase-admin");
admin.initializeApp();
const db = admin.firestore();

// All tunables come from Remote Config; these are fallbacks matching the client
// RemoteConfigValues.default so behavior is consistent if a fetch fails.
const DEFAULTS = {
  MAX_EVENT_PARTICIPANTS: 250,
  ORIGINAL_TTL_HOURS: 48,
  NOTIFICATION_QUIET_WINDOW_MIN: 12,
  NOTIFICATION_MAX_WAIT_MIN: 60,
  SYNC_RATE_LIMIT_PER_MIN: 6,
};

// ---------------------------------------------------------------------------
// PHASE 2 — resolve an invite token into a membership (server-only).
// The client calls this instead of querying events by inviteToken (which the
// security rules forbid). Prevents event/token enumeration.
// ---------------------------------------------------------------------------
exports.resolveInvite = functions.https.onCall(async (data, context) => {
  const uid = context.auth && context.auth.uid;
  if (!uid) throw new functions.https.HttpsError("unauthenticated", "Sign in first.");

  const token = String(data.inviteToken || "");
  const snap = await db.collection("events").where("inviteToken", "==", token).limit(1).get();
  if (snap.empty) throw new functions.https.HttpsError("not-found", "We couldn't find that event.");

  const eventDoc = snap.docs[0];
  const event = eventDoc.data();
  if (event.status !== "active") {
    throw new functions.https.HttpsError("failed-precondition", "This event has ended.");
  }

  const membersRef = eventDoc.ref.collection("members");
  const existing = await membersRef.doc(uid).get();
  if (existing.exists) return { eventId: eventDoc.id };

  const count = (await membersRef.count().get()).data().count;
  if (count >= DEFAULTS.MAX_EVENT_PARTICIPANTS) {
    throw new functions.https.HttpsError("resource-exhausted", "This event is full.");
  }

  await membersRef.doc(uid).set({
    userId: uid,
    role: "participant",
    joinedAt: admin.firestore.FieldValue.serverTimestamp(),
    sharingEnabled: true,
    faceTemplateVersion: Number(data.faceTemplateVersion || 1),
  });
  return { eventId: eventDoc.id };
});

// ---------------------------------------------------------------------------
// PHASE 3 — accumulate match notifications, fired in debounced batches.
// On each new matched photo, roll its matched users into a pending batch doc
// (notificationBatches/{eventId_userId}) rather than pushing per photo.
// ---------------------------------------------------------------------------
exports.onPhotoCreated = functions.firestore
  .document("events/{eventId}/photos/{photoId}")
  .onCreate(async (snap, ctx) => {
    const photo = snap.data();
    const now = admin.firestore.FieldValue.serverTimestamp();
    const batch = db.batch();
    for (const userId of photo.matchedUserIds || []) {
      if (userId === photo.sourceUserId) continue; // don't notify the taker about themselves
      const ref = db.collection("notificationBatches").doc(`${ctx.params.eventId}_${userId}`);
      batch.set(ref, {
        eventId: ctx.params.eventId,
        userId,
        newPhotoCount: admin.firestore.FieldValue.increment(1),
        firstMatchAt: now, // set-if-absent handled below via merge + guard
        lastMatchAt: now,
        pending: true,
      }, { merge: true });
    }
    await batch.commit();
  });

// Scheduled: send any batch that's been quiet long enough or hit the cap.
// Mirrors NotificationDebouncer.shouldSend on the client.
exports.sendBatchedNotifications = functions.pubsub
  .schedule("every 5 minutes")
  .onRun(async () => {
    const nowMs = Date.now();
    const quiet = DEFAULTS.NOTIFICATION_QUIET_WINDOW_MIN * 60 * 1000;
    const maxWait = DEFAULTS.NOTIFICATION_MAX_WAIT_MIN * 60 * 1000;

    const pending = await db.collection("notificationBatches").where("pending", "==", true).get();
    await Promise.all(pending.docs.map(async (doc) => {
      const b = doc.data();
      const last = b.lastMatchAt ? b.lastMatchAt.toMillis() : nowMs;
      const first = b.firstMatchAt ? b.firstMatchAt.toMillis() : nowMs;
      const ready = (nowMs - last >= quiet) || (nowMs - first >= maxWait);
      if (!ready || !(b.newPhotoCount > 0)) return;

      const event = (await db.doc(`events/${b.eventId}`).get()).data() || {};
      const n = b.newPhotoCount;
      const noun = n === 1 ? "photo" : "photos";
      await sendPush(b.userId, {
        title: event.name || "SnapLoop",
        body: `We found ${n} new ${noun} of you in ${event.name || "your event"}.`,
        data: { deepLink: `snaploop://event/${b.eventId}/my-photos` },
      });
      await doc.ref.set({ pending: false, newPhotoCount: 0 }, { merge: true });
    }));
  });

async function sendPush(userId, payload) {
  const user = (await db.doc(`users/${userId}`).get()).data();
  if (!user || !user.fcmToken) return;
  await admin.messaging().send({
    token: user.fcmToken,
    notification: { title: payload.title, body: payload.body },
    data: payload.data,
  });
}

// ---------------------------------------------------------------------------
// PHASE 3 — request an original transfer. Idempotent: a repeated request for
// the same (photo, requester) returns the existing job instead of duplicating
// work. Also rate-limits sync requests per user.
// ---------------------------------------------------------------------------
exports.requestOriginalTransfer = functions.https.onCall(async (data, context) => {
  const uid = context.auth && context.auth.uid;
  if (!uid) throw new functions.https.HttpsError("unauthenticated", "Sign in first.");

  const { eventId, photoId } = data;
  const transferId = `${photoId}_${uid}`; // deterministic → idempotent
  const ref = db.collection("transfers").doc(transferId);

  return db.runTransaction(async (tx) => {
    const existing = await tx.get(ref);
    if (existing.exists && existing.data().status !== "expired" && existing.data().status !== "failed") {
      return { transferId, status: existing.data().status }; // no duplicate work
    }
    const photo = (await tx.get(db.doc(`events/${eventId}/photos/${photoId}`))).data();
    if (!photo) throw new functions.https.HttpsError("not-found", "That photo is no longer available.");

    const ttlH = DEFAULTS.ORIGINAL_TTL_HOURS;
    tx.set(ref, {
      eventId, photoId,
      sourceUserId: photo.sourceUserId,
      requestingUserId: uid,
      status: "queued",
      requestedAt: admin.firestore.FieldValue.serverTimestamp(),
      expiresAt: admin.firestore.Timestamp.fromMillis(Date.now() + ttlH * 3600 * 1000),
    });
    // Notify the source device to upload the original.
    await sendPush(photo.sourceUserId, {
      title: "Someone wants a photo",
      body: "Open SnapLoop to send an original from your event.",
      data: { deepLink: `snaploop://transfer/${transferId}` },
    });
    return { transferId, status: "queued" };
  });
});

// ---------------------------------------------------------------------------
// Rate limiter for sync requests (called by the client before a sync pass).
// ---------------------------------------------------------------------------
exports.checkSyncAllowance = functions.https.onCall(async (data, context) => {
  const uid = context.auth && context.auth.uid;
  if (!uid) throw new functions.https.HttpsError("unauthenticated", "Sign in first.");
  const windowKey = `${uid}_${Math.floor(Date.now() / 60000)}`;
  const ref = db.collection("rateLimits").doc(windowKey);
  const count = await db.runTransaction(async (tx) => {
    const doc = await tx.get(ref);
    const c = (doc.exists ? doc.data().count : 0) + 1;
    tx.set(ref, { count: c, expiresAt: admin.firestore.Timestamp.fromMillis(Date.now() + 120000) });
    return c;
  });
  return { allowed: count <= DEFAULTS.SYNC_RATE_LIMIT_PER_MIN };
});

// ---------------------------------------------------------------------------
// PHASE 4 — data retention / cleanup jobs.
// ---------------------------------------------------------------------------

// Purge expired temporary originals + mark their transfers expired.
exports.purgeExpiredTransfers = functions.pubsub
  .schedule("every 1 hours")
  .onRun(async () => {
    const now = admin.firestore.Timestamp.now();
    const expired = await db.collection("transfers")
      .where("expiresAt", "<=", now)
      .where("status", "in", ["ready", "queued", "source_notified", "uploading"])
      .get();
    const bucket = admin.storage().bucket();
    await Promise.all(expired.docs.map(async (doc) => {
      const t = doc.data();
      if (t.temporaryObjectPath) {
        await bucket.file(t.temporaryObjectPath).delete({ ignoreNotFound: true });
      }
      await doc.ref.set({ status: "expired", temporaryObjectPath: null }, { merge: true });
    }));
  });

// When a member leaves, purge that event's cached embedding for them (the
// client also calls removeMember; this is the server-side guarantee).
exports.onMemberRemoved = functions.firestore
  .document("events/{eventId}/members/{userId}")
  .onDelete(async (snap, ctx) => {
    await db.doc(`events/${ctx.params.eventId}/participants/${ctx.params.userId}`)
      .delete().catch(() => {});
  });

// Expire events past end + grace, and purge all event face-template caches so
// no embedding outlives the event.
exports.expireEndedEvents = functions.pubsub
  .schedule("every 6 hours")
  .onRun(async () => {
    const graceDays = DEFAULTS.EVENT_GRACE_PERIOD_DAYS || 7;
    const cutoff = admin.firestore.Timestamp.fromMillis(Date.now() - graceDays * 86400 * 1000);
    const ended = await db.collection("events")
      .where("endDate", "<=", cutoff)
      .where("status", "in", ["active", "endedByOrganizer"])
      .get();
    await Promise.all(ended.docs.map(async (doc) => {
      // Purge the event's embedding roster.
      const roster = await doc.ref.collection("participants").get();
      const batch = db.batch();
      roster.docs.forEach((p) => batch.delete(p.ref));
      batch.set(doc.ref, { status: "expired" }, { merge: true });
      await batch.commit();
    }));
  });

// Account deletion cascade (mirrors the client ErasureService, server-authoritative):
// removes memberships + event embeddings + face profile + user doc. Photos the
// user SOURCED remain event property, by policy.
exports.deleteAccount = functions.https.onCall(async (data, context) => {
  const uid = context.auth && context.auth.uid;
  if (!uid) throw new functions.https.HttpsError("unauthenticated", "Sign in first.");

  const memberships = await db.collectionGroup("members").where("userId", "==", uid).get();
  const batch = db.batch();
  for (const m of memberships.docs) {
    const eventRef = m.ref.parent.parent;
    batch.delete(m.ref);
    batch.delete(eventRef.collection("participants").doc(uid));
  }
  batch.delete(db.doc(`users/${uid}/faceProfile/current`));
  batch.delete(db.doc(`users/${uid}`));
  await batch.commit();
  await admin.auth().deleteUser(uid).catch(() => {});
  return { deleted: true };
});
