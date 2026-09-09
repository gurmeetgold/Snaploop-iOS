const crypto = require("crypto");
const { onCall, HttpsError } = require("firebase-functions/https");
const { onDocumentCreated, onDocumentWritten } = require("firebase-functions/v2/firestore");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const admin = require("firebase-admin");
const { Timestamp } = require("firebase-admin/firestore");
const { isWithinEventGraceWindow } = require("./eventDateSemantics");
const { normalizePushPlatform } = require("./notificationContract");

const db = admin.firestore();
const messaging = admin.messaging();
const PHOTO_WINDOW_DAYS = 15;

function requireAuth(request) {
  if (!request.auth || !request.auth.uid) {
    throw new HttpsError("unauthenticated", "You must be signed in.");
  }
  return request.auth.uid;
}

function requireToken(value) {
  if (typeof value !== "string" || value.trim().length < 20 || value.length > 4096) {
    throw new HttpsError("invalid-argument", "Push token is invalid.");
  }
  return value.trim();
}

function requireString(value, name) {
  if (typeof value !== "string" || !value.trim()) {
    throw new HttpsError("invalid-argument", `${name} is required.`);
  }
  return value.trim();
}

function tokenKey(token) {
  return crypto.createHash("sha256").update(token).digest("hex");
}

function phoneKey(phone) {
  return String(phone || "").replace(/\D/g, "");
}

function normalizedData(data) {
  const result = {};
  for (const [key, value] of Object.entries(data || {})) {
    if (value === undefined || value === null) continue;
    result[key] = String(value);
  }
  return result;
}

async function tokenDocsForUser(userId) {
  const snap = await db.collection(`users/${userId}/pushTokens`).limit(20).get();
  return snap.docs.filter((doc) => typeof doc.data().token === "string");
}

async function sendPushToUser(userId, { title, body, data = {}, category = null }) {
  const tokenDocs = await tokenDocsForUser(userId);
  if (tokenDocs.length === 0) return { sent: 0 };

  const tokens = tokenDocs.map((doc) => doc.data().token);
  const aps = {
    sound: "default",
    "content-available": 1,
  };
  if (category) aps.category = category;

  const response = await messaging.sendEachForMulticast({
    tokens,
    notification: { title, body },
    data: normalizedData(data),
    apns: {
      payload: { aps },
    },
  });

  const invalidCodes = new Set([
    "messaging/registration-token-not-registered",
    "messaging/invalid-registration-token",
  ]);
  const cleanup = [];
  response.responses.forEach((item, index) => {
    if (!item.success && item.error && invalidCodes.has(item.error.code)) {
      cleanup.push(tokenDocs[index].ref.delete());
    }
  });
  await Promise.allSettled(cleanup);
  return { sent: response.successCount };
}

exports.registerPushToken = onCall(async (request) => {
  const uid = requireAuth(request);
  const input = request.data || {};
  const token = requireToken(input.token);
  const platform = normalizePushPlatform(input.platform);
  const ref = db.doc(`users/${uid}/pushTokens/${tokenKey(token)}`);
  const existing = await ref.get();
  await ref.set({
    token,
    platform,
    appBundleId: typeof input.appBundleId === "string" ? input.appBundleId : null,
    createdAt: existing.exists ? existing.data().createdAt || Timestamp.now() : Timestamp.now(),
    updatedAt: Timestamp.now(),
  }, { merge: true });
  return { registered: true };
});

exports.unregisterPushToken = onCall(async (request) => {
  const uid = requireAuth(request);
  const token = requireToken((request.data || {}).token);
  await db.doc(`users/${uid}/pushTokens/${tokenKey(token)}`).delete();
  return { unregistered: true };
});

exports.revokeEventInvite = onCall(async (request) => {
  const uid = requireAuth(request);
  const input = request.data || {};
  const eventId = requireString(input.eventId, "eventId");
  const phoneNumber = requireString(input.phoneNumber, "phoneNumber");

  const [eventSnap, actorSnap] = await Promise.all([
    db.doc(`events/${eventId}`).get(),
    db.doc(`events/${eventId}/members/${uid}`).get(),
  ]);
  if (!eventSnap.exists) throw new HttpsError("not-found", "This event does not exist.");
  const role = actorSnap.exists ? actorSnap.data().role : null;
  if (role !== "organizer" && role !== "admin") {
    throw new HttpsError("permission-denied", "Only the organizer or an Admin can revoke invitations.");
  }

  const inviteRef = db.doc(`events/${eventId}/invites/${phoneKey(phoneNumber)}`);
  const inviteSnap = await inviteRef.get();
  if (!inviteSnap.exists) return { eventId, revoked: false };
  const invite = inviteSnap.data() || {};
  if (invite.status === "joined") {
    throw new HttpsError("failed-precondition", "This person has already joined the event.");
  }

  const now = Timestamp.now();
  const batch = db.batch();
  batch.set(inviteRef, { status: "revoked", updatedAt: now }, { merge: true });
  if (invite.targetUserId) {
    batch.set(
      db.doc(`users/${invite.targetUserId}/pendingInvites/${eventId}`),
      { status: "revoked", updatedAt: now },
      { merge: true }
    );
  }
  await batch.commit();
  return { eventId, revoked: true };
});

exports.deliverNotificationRecord = onDocumentCreated(
  "users/{userId}/notifications/{notificationId}",
  async (event) => {
    const snap = event.data;
    if (!snap) return;
    const data = snap.data() || {};
    const title = typeof data.title === "string" ? data.title : "MyPicsRoom";
    const body = typeof data.body === "string" ? data.body : "You have an update.";
    await sendPushToUser(event.params.userId, {
      title,
      body,
      data: {
        notificationId: event.params.notificationId,
        type: data.type || "activity",
        eventId: data.eventId || "",
        inviteToken: data.inviteToken || "",
      },
      category: data.type === "event_invite" ? "SNAPLOOP_EVENT_INVITE" : null,
    });
  }
);

exports.notifyPendingInvite = onDocumentWritten(
  "users/{userId}/pendingInvites/{eventId}",
  async (event) => {
    const after = event.data && event.data.after;
    if (!after || !after.exists) return;
    const next = after.data() || {};
    const previous = event.data.before && event.data.before.exists ? event.data.before.data() || {} : {};
    if (next.status !== "invited" || previous.status === "invited") return;

    const eventName = next.eventName || "MyPicsRoom event";
    const notificationId = `invite_${event.params.eventId}_${Date.now()}`;
    await db.doc(`users/${event.params.userId}/notifications/${notificationId}`).set({
      type: "event_invite",
      eventId: event.params.eventId,
      eventName,
      inviteToken: next.inviteToken || null,
      title: "Event invitation",
      body: `You were invited to ${eventName}.`,
      createdAt: Timestamp.now(),
      read: false,
    });
  }
);

exports.markInviteJoined = onDocumentCreated(
  "events/{eventId}/members/{userId}",
  async (event) => {
    const { eventId, userId } = event.params;
    const pendingRef = db.doc(`users/${userId}/pendingInvites/${eventId}`);
    const pendingSnap = await pendingRef.get();
    if (!pendingSnap.exists) return;
    const pending = pendingSnap.data() || {};
    if (pending.status !== "invited") return;

    const batch = db.batch();
    const now = Timestamp.now();
    batch.set(pendingRef, { status: "joined", updatedAt: now }, { merge: true });
    if (pending.phoneNumber) {
      batch.set(
        db.doc(`events/${eventId}/invites/${phoneKey(pending.phoneNumber)}`),
        { status: "joined", updatedAt: now },
        { merge: true }
      );
    }
    await batch.commit();
  }
);

// A phone invite sent before the recipient installs/signs/up is recovered as
// soon as the trusted user profile exists. This is the deferred-invite path and
// does not depend on Safari/App Store preserving arbitrary query parameters.
exports.hydrateDeferredInvites = onDocumentWritten(
  "users/{userId}",
  async (event) => {
    const after = event.data && event.data.after;
    if (!after || !after.exists) return;
    const user = after.data() || {};
    const phone = typeof user.phoneNumber === "string" ? user.phoneNumber : null;
    if (!phone) return;

    const previousPhone = event.data.before && event.data.before.exists
      ? (event.data.before.data() || {}).phoneNumber
      : null;
    if (previousPhone === phone && event.data.before && event.data.before.exists) return;

    const invites = await db.collectionGroup("invites")
      .where("phoneNumber", "==", phone)
      .limit(50)
      .get();

    for (const inviteDoc of invites.docs) {
      const invite = inviteDoc.data() || {};
      if (invite.status !== "invited" || !invite.eventId) continue;

      const eventSnap = await db.doc(`events/${invite.eventId}`).get();
      const eventData = eventSnap.exists ? eventSnap.data() || {} : null;
      const stillJoinable = eventSnap.exists
        && eventData.status === "active"
        && isWithinEventGraceWindow(eventData, Date.now(), PHOTO_WINDOW_DAYS);
      if (!stillJoinable) {
        await inviteDoc.ref.set({ status: "expired", updatedAt: Timestamp.now() }, { merge: true });
        continue;
      }

      const member = await db.doc(`events/${invite.eventId}/members/${event.params.userId}`).get();
      const status = member.exists ? "joined" : "invited";
      const now = Timestamp.now();
      const batch = db.batch();
      batch.set(
        db.doc(`users/${event.params.userId}/pendingInvites/${invite.eventId}`),
        { ...invite, targetUserId: event.params.userId, status, updatedAt: now },
        { merge: true }
      );
      batch.set(inviteDoc.ref, { targetUserId: event.params.userId, status, updatedAt: now }, { merge: true });
      await batch.commit();
    }
  }
);

// Legacy export retained for compatibility with direct module tests. Production
// bootstrap exports inviteExpiry.expirePendingInvites, but both implementations
// now use the same canonical grace predicate.
exports.expirePendingInvites = onSchedule("every 60 minutes", async () => {
  const now = Timestamp.now();
  const snap = await db.collectionGroup("pendingInvites")
    .where("status", "==", "invited")
    .limit(200)
    .get();

  for (const doc of snap.docs) {
    const data = doc.data() || {};
    const eventId = data.eventId || doc.id;
    const eventSnap = await db.doc(`events/${eventId}`).get();
    const eventData = eventSnap.exists ? eventSnap.data() || {} : null;
    if (eventSnap.exists
        && eventData.status === "active"
        && isWithinEventGraceWindow(eventData, now.toMillis(), PHOTO_WINDOW_DAYS)) {
      continue;
    }

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

exports.sendPushToUser = sendPushToUser;
