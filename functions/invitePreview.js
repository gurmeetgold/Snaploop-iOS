const { onRequest, onCall, HttpsError } = require("firebase-functions/v2/https");
const admin = require("firebase-admin");

const db = admin.firestore();

function clean(value) {
  return typeof value === "string" ? value.trim() : "";
}

async function lookupEvent(kind, value) {
  if (!value || (kind !== "e" && kind !== "c")) return null;
  const lookup = kind === "e"
    ? await db.doc(`inviteTokens/${value}`).get()
    : await db.doc(`joinCodes/${value.toUpperCase()}`).get();
  if (!lookup.exists) return null;

  const eventId = clean(lookup.data()?.eventId);
  if (!eventId) return null;
  const eventSnap = await db.doc(`events/${eventId}`).get();
  if (!eventSnap.exists) return null;
  return { eventId, event: eventSnap.data() || {} };
}

async function userDisplayName(uid) {
  const normalized = clean(uid);
  if (!normalized) return "";
  const userSnap = await db.doc(`users/${normalized}`).get();
  return clean(userSnap.data()?.displayName);
}

async function inviterForEvent(eventId, event, viewerUid = "") {
  // A direct phone/in-app invitation records who actually invited this user,
  // including an Admin. Prefer that identity when the preview is requested by
  // the invitee. Generic Event links do not encode a sharer, so they correctly
  // fall back to the Event organizer; the share text itself includes the
  // Admin/organizer who sent the generic link.
  if (viewerUid) {
    const pending = await db.doc(`users/${viewerUid}/pendingInvites/${eventId}`).get();
    const invitedBy = clean(pending.data()?.invitedByUserId);
    const directName = await userDisplayName(invitedBy);
    if (directName) return directName;
  }

  const organizerName = await userDisplayName(event.creatorUserId);
  return organizerName || "A SnapLoop member";
}

function responsePayload(eventId, event, inviterName) {
  return {
    eventId,
    name: clean(event.name) || "SnapLoop Event",
    category: clean(event.category) || "event",
    startsAtMillis: event.startsAt?.toMillis ? event.startsAt.toMillis() : null,
    endsAtMillis: event.endsAt?.toMillis ? event.endsAt.toMillis() : null,
    inviterName,
    status: clean(event.status) || "active",
  };
}

exports.invitePreview = onRequest(async (request, response) => {
  response.set("Cache-Control", "private, max-age=60");
  if (request.method !== "GET") {
    response.status(405).json({ error: "method_not_allowed" });
    return;
  }

  const kind = clean(request.query.kind);
  const value = clean(request.query.value);
  if (!value || (kind !== "e" && kind !== "c")) {
    response.status(400).json({ error: "invalid_invite" });
    return;
  }

  try {
    const resolved = await lookupEvent(kind, value);
    if (!resolved) {
      response.status(404).json({ error: "invite_not_found" });
      return;
    }

    const inviterName = await inviterForEvent(resolved.eventId, resolved.event);
    response.json(responsePayload(resolved.eventId, resolved.event, inviterName));
  } catch (error) {
    console.error("invite preview failed", error);
    response.status(500).json({ error: "preview_unavailable" });
  }
});

exports.resolveInvitePreview = onCall(async (request) => {
  if (!request.auth?.uid) throw new HttpsError("unauthenticated", "You must be signed in.");
  const data = request.data || {};
  const kind = clean(data.kind);
  const value = clean(data.value);
  if (!value || (kind !== "e" && kind !== "c")) {
    throw new HttpsError("invalid-argument", "The Event invitation is invalid.");
  }

  const resolved = await lookupEvent(kind, value);
  if (!resolved) throw new HttpsError("not-found", "That Event invitation does not exist.");

  const inviterName = await inviterForEvent(
    resolved.eventId,
    resolved.event,
    request.auth.uid
  );
  return responsePayload(resolved.eventId, resolved.event, inviterName);
});
