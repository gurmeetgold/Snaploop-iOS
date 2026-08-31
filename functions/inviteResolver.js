const { onCall, HttpsError } = require("firebase-functions/https");
const admin = require("firebase-admin");

const db = admin.firestore();

function requireAuth(request) {
  if (!request.auth?.uid) throw new HttpsError("unauthenticated", "You must be signed in.");
}

function requireString(value, name) {
  if (typeof value !== "string" || !value.trim()) {
    throw new HttpsError("invalid-argument", `${name} is required.`);
  }
  return value.trim();
}

function timestampMillis(value) {
  return value && typeof value.toMillis === "function" ? value.toMillis() : null;
}

function optionalInteger(value) {
  if (value === undefined || value === null) return null;
  const numeric = Number(value);
  return Number.isFinite(numeric) ? Math.trunc(numeric) : null;
}

function eventResponse(eventId, data) {
  return {
    id: eventId,
    joinCode: data.joinCode,
    inviteToken: data.inviteToken,
    creatorUserId: data.creatorUserId,
    name: data.name,
    category: data.category,
    coverImagePath: data.coverImagePath ?? null,
    locationName: data.locationName ?? null,
    startsAtMillis: timestampMillis(data.startsAt),
    endsAtMillis: timestampMillis(data.endsAt),
    photoWindowVersion: optionalInteger(data.photoWindowVersion),
    photoWindowTimeZoneId:
      typeof data.photoWindowTimeZoneId === "string" && data.photoWindowTimeZoneId.trim()
        ? data.photoWindowTimeZoneId.trim()
        : null,
    photoWindowStartDayNumber: optionalInteger(data.photoWindowStartDayNumber),
    photoWindowEndDayNumber: optionalInteger(data.photoWindowEndDayNumber),
    status: data.status,
    createdAtMillis: timestampMillis(data.createdAt),
    updatedAtMillis: timestampMillis(data.updatedAt),
  };
}

/**
 * Authenticated invite/code resolution. Canonical photo-window metadata travels
 * with the preview Event so a participant in another timezone evaluates and
 * displays the organizer-selected civil dates before membership is created.
 */
exports.resolveInviteCanonical = onCall(async (request) => {
  requireAuth(request);
  const data = request.data || {};
  const hasCode = typeof data.joinCode === "string";
  const hasToken = typeof data.inviteToken === "string";

  if (hasCode === hasToken) {
    throw new HttpsError("invalid-argument", "Provide exactly one join code or invite token.");
  }

  const lookupRef = hasCode
    ? db.doc(`joinCodes/${requireString(data.joinCode, "join code").toUpperCase()}`)
    : db.doc(`inviteTokens/${requireString(data.inviteToken, "invite token")}`);
  const lookupSnap = await lookupRef.get();
  if (!lookupSnap.exists) {
    throw new HttpsError(
      "not-found",
      hasCode ? "That join code does not exist." : "That invite does not exist."
    );
  }

  const eventId = requireString((lookupSnap.data() || {}).eventId, "eventId");
  const eventSnap = await db.doc(`events/${eventId}`).get();
  if (!eventSnap.exists) throw new HttpsError("not-found", "That event does not exist.");

  return { event: eventResponse(eventSnap.id, eventSnap.data() || {}) };
});
