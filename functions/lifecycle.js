const { onCall, HttpsError } = require("firebase-functions/https");
const admin = require("firebase-admin");

const db = admin.firestore();
const Timestamp = admin.firestore.Timestamp;

const ALLOWED_TRANSITIONS = {
  active: new Set(["endedByOrganizer", "deletedByOrganizer"]),
  endedByOrganizer: new Set(["active", "deletedByOrganizer"]),
  deletedByOrganizer: new Set(["active"]),
  expired: new Set([]),
};

function requireAuth(request) {
  if (!request.auth || !request.auth.uid) {
    throw new HttpsError("unauthenticated", "You must be signed in.");
  }
  return request.auth.uid;
}

function requireString(value, name) {
  if (typeof value !== "string" || value.trim().length === 0) {
    throw new HttpsError("invalid-argument", `${name} is required.`);
  }
  return value.trim();
}

exports.setEventStatusManaged = onCall(async (request) => {
  const uid = requireAuth(request);
  const data = request.data || {};
  const eventId = requireString(data.eventId, "eventId");
  const requestedStatus = requireString(data.status, "status");

  const eventRef = db.doc(`events/${eventId}`);
  const memberRef = db.doc(`events/${eventId}/members/${uid}`);
  let priorStatus = null;

  await db.runTransaction(async (tx) => {
    const [eventSnap, memberSnap] = await Promise.all([
      tx.get(eventRef),
      tx.get(memberRef),
    ]);
    if (!eventSnap.exists) {
      throw new HttpsError("not-found", "This event does not exist.");
    }
    if (!memberSnap.exists || memberSnap.data().role !== "organizer") {
      throw new HttpsError("permission-denied", "Only the organizer can change event status.");
    }

    const event = eventSnap.data() || {};
    priorStatus = event.status;
    if (priorStatus === requestedStatus) return;

    const allowed = ALLOWED_TRANSITIONS[priorStatus];
    if (!allowed || !allowed.has(requestedStatus)) {
      throw new HttpsError(
        "failed-precondition",
        `Event status cannot change from ${priorStatus || "unknown"} to ${requestedStatus}.`
      );
    }

    tx.update(eventRef, {
      status: requestedStatus,
      updatedAt: Timestamp.now(),
    });
  });

  return { eventId, priorStatus, status: requestedStatus };
});
