const crypto = require("crypto");
const { onCall, HttpsError } = require("firebase-functions/https");
const { onDocumentCreated, onDocumentWritten } = require("firebase-functions/v2/firestore");
const admin = require("firebase-admin");

const db = admin.firestore();
const Timestamp = admin.firestore.Timestamp;
const messaging = admin.messaging();

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

function tokenKey(token) {
  return crypto.createHash("sha256").update(token).digest("hex");
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

async function sendPushToUser(userId, { title, body, data = {} }) {
  const tokenDocs = await tokenDocsForUser(userId);
  if (tokenDocs.length === 0) return { sent: 0 };

  const tokens = tokenDocs.map((doc) => doc.data().token);
  const response = await messaging.sendEachForMulticast({
    tokens,
    notification: { title, body },
    data: normalizedData(data),
    apns: {
      payload: {
        aps: {
          sound: "default",
          "content-available": 1,
        },
      },
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
  const token = requireToken((request.data || {}).token);
  const platform = (request.data || {}).platform === "ios" ? "ios" : "unknown";
  const ref = db.doc(`users/${uid}/pushTokens/${tokenKey(token)}`);
  await ref.set({
    token,
    platform,
    appBundleId: typeof request.data.appBundleId === "string" ? request.data.appBundleId : null,
    createdAt: Timestamp.now(),
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

// Durable activity records are the source of truth. Every new activity record
// fans out to the user's currently registered devices. Invalid FCM tokens are
// removed after send failures so the token collection self-heals.
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
    });
  }
);

// Existing users get an invite immediately without requiring an app relaunch.
// The pending-invite document remains authoritative; this trigger only creates
// a durable notification record when an invite newly enters the invited state.
exports.notifyPendingInvite = onDocumentWritten(
  "users/{userId}/pendingInvites/{eventId}",
  async (event) => {
    const after = event.data && event.data.after;
    if (!after || !after.exists) return;
    const next = after.data() || {};
    const previous = event.data.before && event.data.before.exists ? event.data.before.data() || {} : {};
    if (next.status !== "invited" || previous.status === "invited") return;

    const eventName = next.eventName || "MyPicsRoom event";
    const notificationId = `invite_${event.params.eventId}`;
    await db.doc(`users/${event.params.userId}/notifications/${notificationId}`).set({
      type: "event_invite",
      eventId: event.params.eventId,
      eventName,
      inviteToken: next.inviteToken || null,
      title: "Event invitation",
      body: `You were invited to ${eventName}.`,
      createdAt: Timestamp.now(),
      read: false,
    }, { merge: true });
  }
);

exports.sendPushToUser = sendPushToUser;
