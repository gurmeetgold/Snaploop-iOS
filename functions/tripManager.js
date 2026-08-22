const { onCall, HttpsError } = require("firebase-functions/https");
const admin = require("firebase-admin");
const db = admin.firestore();
const Timestamp = admin.firestore.Timestamp;
const DAY_MS = 24 * 60 * 60 * 1000;
const ALLOWED_CATEGORIES = new Set(["trip","wedding","party","birthday","conference","family","sports","other"]);

function requireAuth(request) {
  if (!request.auth || !request.auth.uid) throw new HttpsError("unauthenticated", "You must be signed in.");
  return request.auth.uid;
}
function cleanString(value, field, max) {
  if (typeof value !== "string") throw new HttpsError("invalid-argument", `${field} is invalid.`);
  const text = value.trim();
  if (!text || text.length > max) throw new HttpsError("invalid-argument", `${field} is invalid.`);
  return text;
}
function optionalLocation(value) {
  if (value === null || value === undefined || value === "") return null;
  if (typeof value !== "string" || value.trim().length > 120) throw new HttpsError("invalid-argument", "Location is invalid.");
  return value.trim();
}
function millis(value, field) {
  const n = Number(value);
  if (!Number.isFinite(n)) throw new HttpsError("invalid-argument", `${field} is invalid.`);
  return n;
}
function validateDates(start, end) {
  if (end <= start || end - start > 15 * DAY_MS + 2 * 60 * 60 * 1000) {
    throw new HttpsError("invalid-argument", "Event dates are invalid or longer than 15 days.");
  }
}
function managerRole(snap) {
  const role = snap.exists ? snap.data().role : null;
  return role === "organizer" || role === "admin";
}

exports.updateTripManaged = onCall(async (request) => {
  const uid = requireAuth(request);
  const data = request.data || {};
  const eventId = cleanString(data.eventId, "Event", 200);
  const eventRef = db.doc(`events/${eventId}`);
  const memberRef = db.doc(`events/${eventId}/members/${uid}`);

  await db.runTransaction(async (tx) => {
    const [eventSnap, memberSnap] = await Promise.all([tx.get(eventRef), tx.get(memberRef)]);
    if (!eventSnap.exists) throw new HttpsError("not-found", "This Event does not exist.");
    if (!managerRole(memberSnap)) throw new HttpsError("permission-denied", "Only the organizer or an Admin can edit this Event.");
    const current = eventSnap.data() || {};
    if (current.status !== "active") throw new HttpsError("failed-precondition", "Only an active Event can be edited.");

    const expected = data.expectedUpdatedAtMillis == null ? null : millis(data.expectedUpdatedAtMillis, "expectedUpdatedAt");
    if (expected !== null && current.updatedAt instanceof Timestamp && Math.abs(current.updatedAt.toMillis() - expected) > 1) {
      throw new HttpsError("aborted", "This Event changed on another device. Refresh before saving.");
    }

    const update = { updatedAt: Timestamp.now() };
    if (data.name !== undefined) update.name = cleanString(data.name, "Event name", 80);
    if (data.category !== undefined) {
      if (!ALLOWED_CATEGORIES.has(data.category)) throw new HttpsError("invalid-argument", "Event category is invalid.");
      update.category = data.category;
    }
    if (Object.prototype.hasOwnProperty.call(data, "locationName")) update.locationName = optionalLocation(data.locationName);
    if (Object.prototype.hasOwnProperty.call(data, "coverImagePath")) update.coverImagePath = typeof data.coverImagePath === "string" ? data.coverImagePath : null;

    if (data.startsAtMillis !== undefined || data.endsAtMillis !== undefined) {
      const start = data.startsAtMillis !== undefined ? millis(data.startsAtMillis, "start") : current.startsAt.toMillis();
      const end = data.endsAtMillis !== undefined ? millis(data.endsAtMillis, "end") : current.endsAt.toMillis();
      validateDates(start, end);
      update.startsAt = Timestamp.fromMillis(start);
      update.endsAt = Timestamp.fromMillis(end);
    }
    tx.update(eventRef, update);
  });
  return { eventId, changed: true };
});

exports.setTripStatusManaged = onCall(async (request) => {
  const uid = requireAuth(request);
  const data = request.data || {};
  const eventId = cleanString(data.eventId, "Event", 200);
  const requested = cleanString(data.status, "status", 40);
  const eventRef = db.doc(`events/${eventId}`);
  const memberRef = db.doc(`events/${eventId}/members/${uid}`);

  await db.runTransaction(async (tx) => {
    const [eventSnap, memberSnap] = await Promise.all([tx.get(eventRef), tx.get(memberRef)]);
    if (!eventSnap.exists) throw new HttpsError("not-found", "This Event does not exist.");
    const role = memberSnap.exists ? memberSnap.data().role : null;
    const current = eventSnap.data() || {};

    if (requested === "endedByOrganizer") {
      if (role !== "organizer" && role !== "admin") throw new HttpsError("permission-denied", "Only the organizer or an Admin can end this Event.");
      if (current.status !== "active") throw new HttpsError("failed-precondition", "Only an active Event can be ended.");
    } else {
      if (role !== "organizer") throw new HttpsError("permission-denied", "Only the organizer can delete, restore, or reopen this Event.");
      const allowed = (current.status === "endedByOrganizer" && requested === "active")
        || (current.status === "deletedByOrganizer" && requested === "active")
        || ((current.status === "active" || current.status === "endedByOrganizer") && requested === "deletedByOrganizer");
      if (!allowed) throw new HttpsError("failed-precondition", "This Event status change is not allowed.");
    }
    tx.update(eventRef, { status: requested, updatedAt: Timestamp.now() });
  });
  return { eventId, status: requested };
});
